// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import SwiftUI
import AppKit
import PostHog
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
    /// Observed so the Pinned Tab Scope row re-renders when a run starts or
    /// finishes; the predicate it reads is `BrowserDataActivity`'s, the same
    /// one the store refuses the change on.
    @ObservedObject private var migrationRunner = BrowserMigrationRunner.shared

    @State private var selectedSpaceId: String?
    @State private var pinnedTabScope: PinnedTabScope = .profile
    @State private var isChangingPinnedTabScope = false
    /// Resolved theme id and color-component slider position for the selected
    /// Space, loaded on selection and updated optimistically (the persistence
    /// stores do not republish `spaces`, so unlike icon/profile these need
    /// local state).
    @State private var spaceThemeId: String = Theme.default.id
    @State private var spaceThemeSliderValue: Double = 0

    @Environment(\.phiAppearance) private var appearance

    /// Drag-reorder state, mirroring SpacesStripView's picker: `orderedIds` is
    /// the live snapshot rearranged as a drag hovers across rows; the persisted
    /// renumbering is written once, on drop, via `SpaceManager.reorder`.
    @State private var draggingSpaceId: String?
    @State private var orderedIds: [String] = []

    private static let spaceListPanelWidth: CGFloat = 280
    private static let detailPanelWidth: CGFloat = 312

    var body: some View {
        ScrollView(.vertical) {
            VStack(spacing: 16) {
                HStack(alignment: .top, spacing: 16) {
                    spaceListPanel
                        .frame(width: Self.spaceListPanelWidth)
                        .frame(maxHeight: .infinity)
                    detailPanel
                        .frame(width: Self.detailPanelWidth)
                        .frame(maxHeight: .infinity, alignment: .top)
                }
                .frame(height: 431)
                SettingsDetailCard {
                    pinnedTabScopeRow
                }
            }
            .frame(maxWidth: .infinity, alignment: .top)
            .padding(.vertical, 36)
            .padding(.horizontal, 36)
        }
        .onAppear {
            profileManager.refresh()
            pinnedTabScope =
                AccountController.shared.localDataAccount?.localStorage.pinnedTabScope()
                ?? .profile
            orderedIds = listedSpaces.map(\.spaceId)
            if selectedSpaceId == nil { selectInitialSpace() }
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
        // color-component slider edits the current theme's value).
        .onReceive(NotificationCenter.default.publisher(for: .spaceThemeDidChange)) { _ in
            syncThemeControls()
        }
        .onReceive(NotificationCenter.default.publisher(for: .themeDidChange)) { _ in
            syncThemeControls()
        }
        .onReceive(NotificationCenter.default.publisher(for: .appearanceDidChange)) { _ in
            syncThemeControls()
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
                Text(NSLocalizedString("settings.spaces.listTitle", value: "Your Spaces", comment: "Spaces settings - list header"))
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
                              help: NSLocalizedString("settings.spaces.newButtonTooltip", value: "New Space", comment: "Spaces settings - new Space tooltip"),
                              action: newSpace)
                toolbarDivider
                toolbarButton(systemName: "minus",
                              help: NSLocalizedString("settings.spaces.deleteButtonTooltip", value: "Delete selected Space", comment: "Spaces settings - delete Space tooltip"),
                              disabled: !canDeleteSelected,
                              action: deleteSelected)
                toolbarDivider
                toolbarButton(systemName: "pencil",
                              help: NSLocalizedString("settings.spaces.renameButtonTooltip", value: "Rename selected Space", comment: "Spaces settings - rename Space tooltip"),
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
                        .customTooltip(space.name)
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
            // Keep long profile names from expanding the surrounding list layout.
            .lineLimit(1)
            .frame(maxWidth: 100, alignment: .trailing)
            .fixedSize(horizontal: false, vertical: true)
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
        // The list panel is 280 wide and the row stack is inset by 6 on each
        // side, so the row — and therefore this preview — is 268 wide.
        .frame(width: 268, alignment: .leading)
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
            // grid scrolls internally), so the theme card's bottom edge lines up
            // with the Space list's bottom edge.
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
                    SettingsDetailRow(NSLocalizedString("settings.spaces.theme.saturationLabel", value: "Saturation", comment: "Spaces settings - theme saturation row label for the per-Space window colors")) {
                        ThemeOpacitySliderView(
                            value: themeSliderBinding(space.spaceId),
                            trackColor: themeSliderTrackColor(space.spaceId),
                            borderColor: ThemedColor.border.resolve(theme: displayedTheme, appearance: appearance),
                            trackStyle: themeSliderTrackStyle,
                            width: Self.themeSliderWidth
                        )
                        .frame(width: Self.themeSliderWidth, height: 20)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(NSLocalizedString("settings.spaces.details.emptyPlaceholder", value: "Select a Space to view its settings.",
                                   comment: "Spaces settings - empty detail placeholder"))
                .font(.system(size: 13))
                .themedForeground(.textSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var pinnedTabScopeRow: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(NSLocalizedString("settings.spaces.pinnedTabScope.title", value: "Pinned tab scope",
                    comment: "Spaces settings - pinned-tab scope row label"
                ))
                .font(.system(size: 13))
                .themedForeground(.textPrimary)

                Text(pinnedTabScopeDescription)
                    .font(.system(size: 11))
                    .themedForeground(.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if migrationRunIsInFlight {
                    Text(NSLocalizedString("settings.spaces.pinnedTabScope.migrationInFlight", value: "Can\u{2019}t be changed while a migration from another browser is running.",
                        comment: "Spaces settings - why the pinned-tab scope picker is disabled during a browser migration"
                    ))
                    .font(.system(size: 11))
                    .themedForeground(.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
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
            .disabled(isChangingPinnedTabScope || migrationRunIsInFlight)
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A Migration in flight owns the pinned tabs it is writing; the scope
    /// they land at is fixed for the length of the run.
    private var migrationRunIsInFlight: Bool {
        BrowserDataActivity.migrationRunIsInFlight
    }

    private var pinnedTabScopeDescription: String {
        switch pinnedTabScope {
        case .space:
            return NSLocalizedString("settings.spaces.pinnedTabScope.spaceDescription", value: "Each Space has its own pinned tabs.",
                comment: "Spaces settings - description of Space pinned-tab scope"
            )
        case .profile:
            return NSLocalizedString("settings.spaces.pinnedTabScope.profileDescription", value: "Spaces using the same profile share pinned tabs.",
                comment: "Spaces settings - description of Profile pinned-tab scope"
            )
        case .app:
            return NSLocalizedString("settings.spaces.pinnedTabScope.appDescription", value: "Pinned tabs are shared across all profiles and Spaces.",
                comment: "Spaces settings - description of App pinned-tab scope"
            )
        }
    }

    private func pinnedTabScopeName(_ scope: PinnedTabScope) -> String {
        switch scope {
        case .space:
            return NSLocalizedString("settings.spaces.pinnedTabScope.spaceOption", value: "Space", comment: "Spaces settings - Space pinned-tab scope option")
        case .profile:
            return NSLocalizedString("settings.spaces.pinnedTabScope.profileOption", value: "Profile", comment: "Spaces settings - Profile pinned-tab scope option")
        case .app:
            return NSLocalizedString("settings.spaces.pinnedTabScope.appOption", value: "App", comment: "Spaces settings - App pinned-tab scope option")
        }
    }

    private func requestPinnedTabScopeChange(to newScope: PinnedTabScope) {
        guard newScope != pinnedTabScope,
              !isChangingPinnedTabScope else { return }

        let previousScope = pinnedTabScope
        let isCopy = newScope.hierarchyLevel < previousScope.hierarchyLevel
        pinnedTabScope = newScope

        guard let store = AccountController.shared.localDataAccount?.localStorage else {
            pinnedTabScope = previousScope
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = NSLocalizedString("settings.spaces.pinnedTabScopeConfirmation.title", value: "Change Pinned Tab Scope?",
            comment: "Spaces settings - title of pinned-tab scope migration confirmation"
        )
        alert.informativeText = isCopy
            ? NSLocalizedString("settings.spaces.pinnedTabScopeConfirmation.narrowingMessage", value: "Your current pinned tabs will be copied into each existing destination. The copies can then be changed independently.",
                comment: "Spaces settings - confirmation body for narrowing pinned-tab scope"
            )
            : NSLocalizedString("settings.spaces.pinnedTabScopeConfirmation.broadeningMessage", value: "Pinned tabs from the existing destinations will be merged. Unchanged copies will be combined, while different versions will be kept.",
                comment: "Spaces settings - confirmation body for broadening pinned-tab scope"
            )
        alert.addButton(withTitle: NSLocalizedString("settings.spaces.pinnedTabScopeConfirmation.confirmButton", value: "Change Scope", comment: "Spaces settings - confirm pinned-tab scope change"))
        alert.addButton(withTitle: NSLocalizedString("settings.spaces.pinnedTabScopeConfirmation.cancelButton", value: "Cancel", comment: "Cancel button"))
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
                errorAlert.messageText = NSLocalizedString("settings.spaces.pinnedTabScopeFailure.title", value: "Pinned Tab Scope Wasn’t Changed",
                    comment: "Spaces settings - pinned-tab scope migration error title"
                )
                errorAlert.informativeText = error.localizedDescription
                errorAlert.addButton(withTitle: NSLocalizedString("settings.spaces.pinnedTabScopeFailure.dismissButton", value: "OK", comment: "Dismiss button"))
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

    /// Loads the selected Space's resolved theme id and effective color
    /// component into the local control state.
    private func syncThemeControls() {
        guard let spaceId = selectedSpaceId else { return }
        spaceThemeId = spaceManager.resolvedThemeId(forSpaceId: spaceId)
        let appearance = ThemeManager.shared.currentAppearance
        if spaceThemeId == Theme.pure.id {
            spaceThemeSliderValue = spaceManager.effectivePureThemeSliderValue(
                forSpaceId: spaceId,
                appearance: appearance
            )
        } else {
            let saturation = spaceManager.effectiveOverlaySaturation(
                forSpaceId: spaceId,
                appearance: appearance
            )
            spaceThemeSliderValue = OverlaySaturationScale.sliderValue(
                forSaturation: Double(saturation)
            )
        }
    }

    // MARK: - Detail bindings

    private static let themeSliderWidth: CGFloat = 200
    private static let themeSwatchDiameter: CGFloat = 16
    private static let themeSwatchRingDiameter: CGFloat = 20
    private static let themeSwatchSpacing: CGFloat = 10
    private static let themeSwatchTitleFontSize: CGFloat = 10

    private var themeSliderTrackStyle: ThemeSliderTrackStyle {
        spaceThemeId == Theme.pure.id ? .pureBrightness(appearance) : .saturation
    }

    /// Inline theme swatch row mirroring the General pane's Color row: one
    /// dot per built-in theme, the Space's resolved theme ringed with its
    /// name captioned underneath. Compact sizing so all eight dots fit the
    /// narrower detail card.
    private func colorRow(_ spaceId: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(NSLocalizedString("settings.spaces.theme.colorLabel", value: "Color", comment: "Spaces settings - theme color row label"))
                .font(.system(size: 13))
                .themedForeground(.textPrimary)
                // The swatch row eats most of the card width; never let the
                // label wrap into a vertical letter stack.
                .lineLimit(1)
                .fixedSize()

            Spacer(minLength: 8)

            HStack(alignment: .top, spacing: Self.themeSwatchSpacing) {
                ForEach(ThemeManager.shared.orderedThemes, id: \.id) { theme in
                    ThemeSwatchView(
                        fillColor: theme == .pure
                            ? .white
                            : Color(theme.color(for: .themeColor, appearance: appearance)),
                        ringColor: Color(theme.color(for: .themeColor, appearance: appearance)),
                        selected: spaceThemeId == theme.id,
                        title: theme.name,
                        showsContrastBorder: theme == .pure,
                        dotDiameter: Self.themeSwatchDiameter,
                        ringDiameter: Self.themeSwatchRingDiameter,
                        titleFontSize: Self.themeSwatchTitleFontSize,
                        action: { selectTheme(theme.id, for: spaceId) }
                    )
                    .frame(width: Self.themeSwatchDiameter)
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
        // Saturation and Pure brightness are stored separately, so switching
        // themes restores the selected theme kind's previous adjustment.
        syncThemeControls()
    }

    private func themeSliderBinding(_ spaceId: String) -> Binding<Double> {
        Binding(
            get: { spaceThemeSliderValue },
            set: { newValue in
                spaceThemeSliderValue = newValue
                if spaceManager.resolvedThemeId(forSpaceId: spaceId) == Theme.pure.id {
                    spaceManager.setPureThemeSliderValue(
                        newValue,
                        forSpaceId: spaceId
                    )
                } else {
                    let saturation = OverlaySaturationScale.saturation(
                        forSlider: newValue
                    )
                    spaceManager.setOverlaySaturation(
                        CGFloat(saturation),
                        forSpaceId: spaceId,
                        appearance: ThemeManager.shared.currentAppearance
                    )
                }
            }
        )
    }

    /// The gradient base behind the color-component slider.
    private func themeSliderTrackColor(_ spaceId: String) -> NSColor {
        spaceManager.resolvedTheme(forSpaceId: spaceId)
            .color(for: .windowOverlayBackground, appearance: appearance)
    }

    /// The selected Space's theme instance, for chrome derived from it
    /// (the saturation slider's border color).
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
        alert.messageText = NSLocalizedString("settings.spaces.renameDialog.title", value: "Rename Space", comment: "Title of the rename-Space dialog")
        alert.informativeText = NSLocalizedString("settings.spaces.renameDialog.message", value: "Enter a new name for this Space.", comment: "Body of the rename-Space dialog")
        alert.addButton(withTitle: NSLocalizedString("settings.spaces.renameDialog.renameButton", value: "Rename", comment: "Rename button"))
        alert.addButton(withTitle: NSLocalizedString("settings.spaces.renameDialog.cancelButton", value: "Cancel", comment: "Cancel button"))
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
            format: NSLocalizedString("settings.spaces.changeProfileConfirmation.title", value: "Change Profile to \u{201C}%@\u{201D}?", comment: "Title of the change-Space-profile confirmation"),
            profile.displayName
        )
        alert.informativeText = changeProfileConfirmationBody
        alert.addButton(withTitle: NSLocalizedString("settings.spaces.changeProfileConfirmation.confirmButton", value: "Change Profile", comment: "Confirm button of the change-Space-profile confirmation"))
        alert.addButton(withTitle: NSLocalizedString("settings.spaces.changeProfileConfirmation.cancelButton", value: "Cancel", comment: "Cancel button"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        spaceManager.changeProfile(spaceId: spaceId, toProfileId: profile.profileId)
    }

    private func deleteSpace(_ space: SpaceModel) {
        guard space.spaceId != LocalStore.defaultSpaceId else { return }
        let alert = NSAlert()
        alert.messageText = String(
            format: NSLocalizedString("settings.spaces.deleteConfirmation.title", value: "Delete \u{201C}%@\u{201D}?", comment: "Title of the delete-Space confirmation"),
            space.name
        )
        alert.informativeText = deleteSpaceConfirmationBody
        alert.alertStyle = .warning
        alert.addButton(withTitle: NSLocalizedString("settings.spaces.deleteConfirmation.deleteButton", value: "Delete", comment: "Destructive button"))
        alert.addButton(withTitle: NSLocalizedString("settings.spaces.deleteConfirmation.cancelButton", value: "Cancel", comment: "Cancel button"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        spaceManager.deleteSpace(spaceId: space.spaceId)
        PostHogSDK.shared.capture("space_deleted")
    }

    private var changeProfileConfirmationBody: String {
        switch pinnedTabScope {
        case .space:
            return NSLocalizedString("settings.spaces.changeProfileConfirmation.spaceScopedMessage", value: "This Space's window will be reopened with the new profile and its open tabs will be reloaded there. Site logins won't carry over. Bookmarks and pinned tabs stay with the Space.",
                comment: "Body of the change-Space-profile confirmation with Space-scoped pinned tabs"
            )
        case .profile:
            return NSLocalizedString("settings.spaces.changeProfileConfirmation.profileScopedMessage", value: "This Space's window will be reopened with the new profile and its open tabs will be reloaded there. Site logins won't carry over. Bookmarks stay with the Space; pinned tabs will be the new profile's.",
                comment: "Body of the change-Space-profile confirmation with Profile-scoped pinned tabs"
            )
        case .app:
            return NSLocalizedString("settings.spaces.changeProfileConfirmation.appScopedMessage", value: "This Space's window will be reopened with the new profile and its open tabs will be reloaded there. Site logins won't carry over. Bookmarks stay with the Space; pinned tabs remain shared across the app.",
                comment: "Body of the change-Space-profile confirmation with App-scoped pinned tabs"
            )
        }
    }

    private var deleteSpaceConfirmationBody: String {
        if pinnedTabScope == .space {
            return NSLocalizedString("settings.spaces.deleteConfirmation.spaceScopedMessage", value: "Bookmarks and pinned tabs belonging to this Space will also be removed. This action cannot be undone.",
                comment: "Body of the delete-Space confirmation with Space-scoped pinned tabs"
            )
        }
        return NSLocalizedString("settings.spaces.deleteConfirmation.message", value: "Bookmarks belonging to this Space will also be removed. This action cannot be undone.",
            comment: "Body of the delete-Space confirmation"
        )
    }
}

// The whole-list fallback drop target (`SpaceListResetDropDelegate`) is shared
// with the sidebar strip and picker; it lives next to `SpaceRowDropDelegate` in
// SpacesStripView.swift.

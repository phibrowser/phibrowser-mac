// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// State machine for the trackpad swipe-to-switch-Space gesture, shared by
/// the sidebar (vertical layouts) and the tab strip bar (traditional
/// layout). The gesture's axis is latched on the first non-zero delta and
/// holds for the rest of the gesture (including momentum), so a swipe that
/// drifts diagonally doesn't alternate between scrolling and switching.
/// Horizontal-dominant gestures are consumed entirely; callers forward
/// `.passthrough` events to `super.scrollWheel`.
final class SpaceSwipeTracker {
    enum Outcome {
        /// Legacy wheel event or vertical-dominant gesture — scroll as usual.
        case passthrough
        /// Part of a horizontal gesture; swallow without acting.
        case consumed
        /// Horizontal travel crossed the threshold — fired once per gesture.
        /// The deltas follow `scrollingDeltaX` as-is, so the system
        /// scroll-direction setting applies: content-left means the next
        /// Space (+1), content-right the previous (-1).
        case trigger(step: Int)
    }

    private enum Axis { case undecided, horizontal, vertical }
    private var axis: Axis = .undecided
    private var accumulatedX: CGFloat = 0
    private var triggered = false
    private static let threshold: CGFloat = 50

    func handle(_ event: NSEvent) -> Outcome {
        // Legacy wheel events carry no gesture phases; never treat them as
        // swipes.
        guard event.phase != [] || event.momentumPhase != [] else { return .passthrough }

        if event.phase == .mayBegin || event.phase == .began {
            axis = .undecided
            accumulatedX = 0
            triggered = false
        }

        if axis == .undecided {
            let dx = abs(event.scrollingDeltaX)
            let dy = abs(event.scrollingDeltaY)
            if dx > dy {
                axis = .horizontal
            } else if dy > dx {
                axis = .vertical
            }
        }

        guard axis == .horizontal else { return .passthrough }

        accumulatedX += event.scrollingDeltaX
        if !triggered, abs(accumulatedX) >= Self.threshold {
            triggered = true
            return .trigger(step: accumulatedX < 0 ? 1 : -1)
        }
        return .consumed
    }
}

/// Compact active-Space header that sits between the pinned-tab strip and
/// the regular tab list. Shows the active Space's icon + name on the left
/// and an ellipsis affordance on the right that opens a popover listing
/// every Space (with its bound profile) plus a "+" row to create a new one.
///
/// Per-Space actions (rename / icon / theme / URL rules / delete) live on
/// each popover row's context menu — the picker is also the place to edit
/// existing Spaces, so the user never has to leave it once it's open.
struct SpacesStripView: View {
    @ObservedObject var manager: SpaceManager
    /// Per-window slot driving the active-Space highlight and the destination
    /// of activations. Each window's sidebar gets its own slot, so clicks here
    /// only affect this window.
    @ObservedObject var slot: SpaceWindowSlot
    /// Row height. The sidebar mounts a slimmer row than the horizontal
    /// toolbar; this also sizes the scrolling-label clip window.
    var rowHeight: CGFloat = SpacesStripView.height
    /// When false (horizontal tab strip), the switch is a compact icon+name
    /// chip with no trailing ellipsis — tapping the chip opens the picker.
    /// When true (sidebar), the label sits left with a trailing ellipsis
    /// affordance and a spacer between them.
    var showsEllipsisAffordance: Bool = true
    @ObservedObject private var profileManager: ProfileManager = .shared
    @Environment(\.phiAppearance) private var windowAppearance: Appearance

    @State private var isPickerOpen: Bool = false

    /// The Space whose icon + name are currently shown. Lags `slot.activeSpaceId`
    /// by one animated step so the label can scroll the outgoing Space out and
    /// the incoming one in. `scrollEdge` is set just before the animated change
    /// so the motion direction matches the Space order (later Space → scroll up).
    @State private var displayedSpaceId: String?
    @State private var scrollEdge: Edge = .bottom

    /// Single-row height — matches the visual rhythm of pinned-tab rows above.
    static let height: CGFloat = 30
    /// Slimmer height used when the switch sits at the top of the sidebar.
    static let sidebarHeight: CGFloat = 24
    private static let horizontalPadding: CGFloat = 10
    private static let iconSize: CGFloat = 14

    /// Preset palette used for new-Space creation. Ordered so successive new
    /// Spaces are visually distinct without forcing the user into a color
    /// picker on creation.
    static let colorPalette: [(hex: String, name: String)] = [
        ("#3A6FF8", "Blue"),
        ("#E5484D", "Red"),
        ("#46A758", "Green"),
        ("#F76B15", "Orange"),
        ("#8E4EC6", "Purple"),
        ("#0091FF", "Cyan")
    ]

    /// SF Symbol options exposed in the per-Space "Change Icon" submenu.
    /// Curated so every entry reads at the row's small icon rendering.
    static let iconOptions: [String] = [
        "rectangle.stack",
        "house",
        "briefcase",
        "book",
        "folder",
        "graduationcap",
        "person",
        "star",
        "heart",
        "gamecontroller",
        "music.note",
        "leaf"
    ]

    var body: some View {
        // Height is set by the caller (SnapKit constraint in the sidebar,
        // SwiftUI frame in the horizontal toolbar) so the picker can adapt
        // to whichever row it's plugged into.
        Group {
            if showsEllipsisAffordance {
                HStack(spacing: 6) {
                    activeLabel
                    Spacer(minLength: 4)
                    ellipsisButton
                }
            } else {
                compactChip
            }
        }
        .padding(.horizontal, Self.horizontalPadding)
        .contentShape(Rectangle())
    }

    /// Compact tap target for the horizontal tab strip: the active Space's
    /// icon + name with no trailing ellipsis, opening the picker on click.
    private var compactChip: some View {
        Button {
            isPickerOpen.toggle()
        } label: {
            activeLabel
        }
        .buttonStyle(.plain)
        .help(NSLocalizedString("Spaces", comment: "Tooltip for the Spaces picker affordance"))
        .popover(isPresented: $isPickerOpen, arrowEdge: .top) {
            pickerPopup
        }
    }

    /// Active Space's icon + name. The per-Space tweaks (rename, change icon,
    /// edit theme, change profile) now live in the Spaces menu and the
    /// tab-area / sidebar context menu, so the header no longer carries its
    /// own right-click menu.
    @ViewBuilder
    private var activeLabel: some View {
        scrollingLabel
        .contentShape(Rectangle())
    }

    private func prettyIconLabel(_ id: String) -> String {
        id.split(separator: ".")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    /// Icon + name that scrolls vertically when the active Space changes: the
    /// outgoing Space slides off one edge while the incoming one slides in from
    /// the other (later Space → scroll up, earlier → scroll down), clipped to
    /// the row height so it reads as a ticker.
    private var scrollingLabel: some View {
        // The clip + fixed frame live on the STABLE container (the ZStack), not
        // on the transitioning label — otherwise the clip travels out with the
        // outgoing label and the old name lingers above/below the row.
        ZStack(alignment: .leading) {
            label(for: spaceModel(displayedSpaceId))
                .id(displayedSpaceId ?? "none")
                .transition(.asymmetric(
                    insertion: .move(edge: scrollEdge).combined(with: .opacity),
                    removal: .move(edge: scrollEdge == .bottom ? .top : .bottom).combined(with: .opacity)
                ))
        }
        .frame(height: rowHeight, alignment: .leading)
        .clipped()
        .onAppear {
            if displayedSpaceId == nil { displayedSpaceId = slot.activeSpaceId }
        }
        .onChange(of: slot.activeSpaceId) { newId in
            let oldIndex = manager.spaces.firstIndex { $0.spaceId == displayedSpaceId }
            let newIndex = manager.spaces.firstIndex { $0.spaceId == newId }
            scrollEdge = (newIndex ?? 0) >= (oldIndex ?? 0) ? .bottom : .top
            // Match the band push-in exactly (same curve + duration) so the
            // name scroll and the slide move together.
            withAnimation(.easeInOut(duration: PhiPreferences.GeneralSettings.loadSwitchSpaceAnimationDuration())) {
                displayedSpaceId = newId
            }
        }
    }

    private func spaceModel(_ id: String?) -> SpaceModel? {
        guard let id else { return nil }
        return manager.spaces.first { $0.spaceId == id }
    }

    private func label(for space: SpaceModel?) -> some View {
        HStack(spacing: 6) {
            icon(for: space)
            name(for: space)
        }
    }

    @ViewBuilder
    private func icon(for space: SpaceModel?) -> some View {
        if let space, let symbol = systemSymbolName(for: space.iconName) {
            Image(systemName: symbol)
                .font(.system(size: Self.iconSize, weight: .semibold))
                .foregroundStyle(iconColor(for: space))
        } else {
            Image(systemName: "rectangle.stack")
                .font(.system(size: Self.iconSize, weight: .semibold))
                .foregroundStyle(Color.secondary)
        }
    }

    private func name(for space: SpaceModel?) -> some View {
        Text(space?.name ?? NSLocalizedString("No Space", comment: "Active-Space header fallback when no Space is selected"))
            .font(.system(size: 13, weight: .medium))
            .lineLimit(1)
            .truncationMode(.tail)
    }

    private var ellipsisButton: some View {
        Button {
            isPickerOpen.toggle()
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(NSLocalizedString("Spaces", comment: "Tooltip for the Spaces picker affordance"))
        .popover(isPresented: $isPickerOpen, arrowEdge: .top) {
            pickerPopup
        }
    }

    /// The Space-switcher popover content, shared by the sidebar's ellipsis
    /// affordance and the horizontal strip's compact chip.
    @ViewBuilder
    private var pickerPopup: some View {
        SpacePickerPopup(
            manager: manager,
            slot: slot,
            profileManager: profileManager,
            windowAppearance: windowAppearance,
            onActivate: { spaceId in
                slot.activate(spaceId: spaceId)
                isPickerOpen = false
            },
            onRename: { space in
                isPickerOpen = false
                promptRename(for: space)
            },
            onChangeIcon: { manager.changeIcon(spaceId: $0, iconName: $1) },
            onSetTheme: { manager.setTheme(forSpaceId: $0, themeId: $1) },
            currentThemeId: { manager.themeId(forSpaceId: $0) },
            onDelete: { space in
                isPickerOpen = false
                confirmDelete(space)
            }
        )
    }

    private var activeSpace: SpaceModel? {
        if let id = slot.activeSpaceId {
            return manager.spaces.first { $0.spaceId == id }
        }
        return nil
    }

    /// Resolves a Space's bound profile to a user-visible name, falling back to
    /// the raw profileId if ProfileManager hasn't refreshed yet.
    private func profileDisplayName(for profileId: String) -> String {
        profileManager.profile(for: profileId)?.displayName ?? profileId
    }

    /// Each Space's accent comes from its pinned theme (or the global theme
    /// when no override is set), so the active-Space icon previews what the
    /// window currently looks like.
    fileprivate func iconColor(for space: SpaceModel) -> Color {
        let theme: Theme
        if let pinnedId = manager.themeId(forSpaceId: space.spaceId),
           let pinned = ThemeManager.shared.registeredThemes[pinnedId] {
            theme = pinned
        } else {
            theme = ThemeManager.shared.currentTheme
        }
        return Color(nsColor: theme.color(for: .textPrimary, appearance: windowAppearance))
    }

    private func promptRename(for space: SpaceModel) {
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
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }
        let trimmed = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != space.name else { return }
        manager.renameSpace(spaceId: space.spaceId, to: trimmed)
    }

    private func confirmDelete(_ space: SpaceModel) {
        let alert = NSAlert()
        alert.messageText = String(
            format: NSLocalizedString("Delete \u{201C}%@\u{201D}?", comment: "Title of the delete-Space confirmation"),
            space.name
        )
        alert.informativeText = NSLocalizedString(
            "Pinned tabs and bookmarks belonging to this Space will also be removed. This action cannot be undone.",
            comment: "Body of the delete-Space confirmation"
        )
        alert.alertStyle = .warning
        alert.addButton(withTitle: NSLocalizedString("Delete", comment: "Destructive button"))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Cancel button"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        manager.deleteSpace(spaceId: space.spaceId)
    }
}

/// Popover content shown by the ellipsis button. Lists every Space with its
/// bound profile label, plus a footer row for creating a new one. Each row
/// is clickable to activate and right-clickable to edit / delete.
private struct SpacePickerPopup: View {
    @ObservedObject var manager: SpaceManager
    @ObservedObject var slot: SpaceWindowSlot
    @ObservedObject var profileManager: ProfileManager
    let windowAppearance: Appearance
    let onActivate: (String) -> Void
    let onRename: (SpaceModel) -> Void
    let onChangeIcon: (String, String) -> Void
    let onSetTheme: (String, String?) -> Void
    let currentThemeId: (String) -> String?
    let onDelete: (SpaceModel) -> Void

    private static let popoverWidth: CGFloat = 240

    @State private var draggingSpaceId: String?
    @State private var orderedIds: [String] = []

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(orderedSpaces, id: \.spaceId) { space in
                        SpacePickerRow(
                            space: space,
                            isActive: space.spaceId == slot.activeSpaceId,
                            isDeletable: space.spaceId != LocalStore.defaultSpaceId,
                            tint: iconColor(for: space),
                            profileName: profileDisplayName(for: space.profileId),
                            onActivate: { onActivate(space.spaceId) },
                            onRename: { onRename(space) },
                            onChangeIcon: { onChangeIcon(space.spaceId, $0) },
                            onSetTheme: { onSetTheme(space.spaceId, $0) },
                            currentThemeId: { currentThemeId(space.spaceId) },
                            onDelete: { onDelete(space) }
                        )
                        .opacity(draggingSpaceId == space.spaceId ? 0.5 : 1)
                        .onDrag {
                            draggingSpaceId = space.spaceId
                            return NSItemProvider(object: space.spaceId as NSString)
                        }
                        .onDrop(of: [.text], delegate: SpaceRowDropDelegate(
                            targetSpaceId: space.spaceId,
                            draggingSpaceId: $draggingSpaceId,
                            orderedIds: $orderedIds,
                            commit: { manager.reorder(spaceIds: $0) }
                        ))
                    }
                }
                .padding(.vertical, 6)
            }
        }
        .frame(width: Self.popoverWidth)
        .frame(maxHeight: 320)
        .onAppear { orderedIds = manager.spaces.map(\.spaceId) }
        .onChange(of: manager.spaces.map(\.spaceId)) { ids in
            // Don't fight an in-flight drag's local rearrangement; the
            // commit on drop writes through and re-syncs on the next pass.
            guard draggingSpaceId == nil else { return }
            orderedIds = ids
        }
    }

    /// Rows in drag order: the local `orderedIds` snapshot (rearranged live
    /// while a drag hovers across rows), with any Space the snapshot doesn't
    /// know yet appended in strip order.
    private var orderedSpaces: [SpaceModel] {
        guard !orderedIds.isEmpty else { return manager.spaces }
        let byId = Dictionary(uniqueKeysWithValues: manager.spaces.map { ($0.spaceId, $0) })
        var result = orderedIds.compactMap { byId[$0] }
        let known = Set(orderedIds)
        result.append(contentsOf: manager.spaces.filter { !known.contains($0.spaceId) })
        return result
    }

    private func iconColor(for space: SpaceModel) -> Color {
        let theme: Theme
        if let pinnedId = manager.themeId(forSpaceId: space.spaceId),
           let pinned = ThemeManager.shared.registeredThemes[pinnedId] {
            theme = pinned
        } else {
            theme = ThemeManager.shared.currentTheme
        }
        return Color(nsColor: theme.color(for: .textPrimary, appearance: windowAppearance))
    }

    /// Falls back to the raw profileId so the row still shows *something*
    /// useful if ProfileManager hasn't refreshed yet (e.g. very early after
    /// bridge bring-up).
    private func profileDisplayName(for profileId: String) -> String {
        if let p = ProfileManager.shared.profile(for: profileId) {
            return p.displayName
        }
        return profileId
    }
}

/// Reorders the picker rows live while a row drag hovers over siblings and
/// commits the arrangement on drop. Movement happens in the popup's local
/// `orderedIds` (not the persisted list), so SwiftData is written once —
/// when the drop lands — rather than on every row crossing.
private struct SpaceRowDropDelegate: DropDelegate {
    let targetSpaceId: String
    @Binding var draggingSpaceId: String?
    @Binding var orderedIds: [String]
    let commit: ([String]) -> Void

    func dropEntered(info: DropInfo) {
        guard let dragging = draggingSpaceId,
              dragging != targetSpaceId,
              let from = orderedIds.firstIndex(of: dragging),
              let to = orderedIds.firstIndex(of: targetSpaceId) else { return }
        withAnimation(.easeInOut(duration: 0.15)) {
            orderedIds.move(
                fromOffsets: IndexSet(integer: from),
                toOffset: to > from ? to + 1 : to
            )
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggingSpaceId = nil
        commit(orderedIds)
        return true
    }
}

private struct SpacePickerRow: View {
    let space: SpaceModel
    let isActive: Bool
    let isDeletable: Bool
    let tint: Color
    let profileName: String
    let onActivate: () -> Void
    let onRename: () -> Void
    let onChangeIcon: (String) -> Void
    let onSetTheme: (String?) -> Void
    let currentThemeId: () -> String?
    let onDelete: () -> Void

    @State private var isHovering: Bool = false

    var body: some View {
        Button(action: onActivate) {
            HStack(spacing: 8) {
                if let symbol = systemSymbolName(for: space.iconName) {
                    Image(systemName: symbol)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(isActive ? Color.white : tint)
                        .frame(width: 16)
                } else {
                    Image(systemName: "rectangle.stack")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(isActive ? Color.white : tint)
                        .frame(width: 16)
                }
                Text(space.name)
                    .font(.system(size: 13, weight: isActive ? .semibold : .regular))
                    .lineLimit(1)
                    .foregroundStyle(isActive ? Color.white : Color.primary)
                Spacer(minLength: 8)
                Text(profileName)
                    .font(.system(size: 11))
                    .foregroundStyle(isActive ? Color.white.opacity(0.85) : Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(rowBackground)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovering = hovering
        }
        .contextMenu {
            Button(NSLocalizedString("Rename\u{2026}", comment: "")) { onRename() }
            Menu(NSLocalizedString("Change Icon", comment: "")) {
                ForEach(SpacesStripView.iconOptions, id: \.self) { icon in
                    Button {
                        onChangeIcon(icon)
                    } label: {
                        Label(prettyIconLabel(icon), systemImage: icon)
                    }
                }
            }
            Menu(NSLocalizedString("Change Theme", comment: "")) {
                let pinnedId = currentThemeId()
                Button {
                    onSetTheme(nil)
                } label: {
                    if pinnedId == nil {
                        Label(NSLocalizedString("Follow Global", comment: "Theme menu: clear per-Space override"), systemImage: "checkmark")
                    } else {
                        Text(NSLocalizedString("Follow Global", comment: "Theme menu: clear per-Space override"))
                    }
                }
                Divider()
                ForEach(Self.sortedRegisteredThemes(), id: \.id) { theme in
                    Button {
                        onSetTheme(theme.id)
                    } label: {
                        if pinnedId == theme.id {
                            Label(theme.name, systemImage: "checkmark")
                        } else {
                            Text(theme.name)
                        }
                    }
                }
            }
            if isDeletable {
                Divider()
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Text(NSLocalizedString("Delete", comment: "Destructive menu item"))
                }
            }
        }
    }

    @ViewBuilder
    private var rowBackground: some View {
        if isActive {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.accentColor)
                .padding(.horizontal, 6)
        } else if isHovering {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.08))
                .padding(.horizontal, 6)
        } else {
            Color.clear
        }
    }

    private func prettyIconLabel(_ id: String) -> String {
        id.split(separator: ".")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    static func sortedRegisteredThemes() -> [Theme] {
        ThemeManager.shared.registeredThemes.values
            .sorted { lhs, rhs in lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending }
    }
}

/// SpaceModel.iconName is stored as an SF Symbol id (e.g. "rectangle.stack").
/// Resolved at view time so future themes / icon packs can intercept here
/// rather than at the persistence layer.
private func systemSymbolName(for stored: String) -> String? {
    stored.isEmpty ? nil : stored
}

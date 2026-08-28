// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import PostHog
import SwiftUI

/// Rich "Create a Space" panel. Replaces the bare name-only NSAlert that used
/// to back both the File menu and the Spaces picker's "New Space" row. Lets the
/// user name the Space, bind it to a profile, and pick its theme before
/// committing.
///
/// Self-contained: the only side effect is `manager.createSpace(...)` on
/// confirm. Presented in a chrome-light floating window via `present(...)`,
/// which both entry points call so the window setup lives in one place.
struct CreateSpacePanel: View {
    enum Style {
        /// Floating window — used in the horizontal (Comfortable) layout and
        /// whenever no usable sidebar is available.
        case window
        /// Fills the sidebar in vertical (Performance / Balanced) layouts.
        case sidebar
    }

    var style: Style = .window
    @ObservedObject var manager: SpaceManager
    @ObservedObject var profileManager: ProfileManager
    /// Profile the picker opens on — the active Space's profile when reached
    /// from the sidebar, or the menu's active-window profile.
    let initialProfileId: String?
    /// The source Space's theme when the panel opens. The random theme the
    /// form seeds on appear excludes it — a new Space must arrive looking
    /// different from the Space it was created from — and it remains the
    /// fallback while no selection is resolved.
    let initialThemeId: String
    /// Whether the host should restore the theme that preceded its live
    /// preview. Successful creation keeps the selected preview in place until
    /// the new Space is activated, avoiding a flash of the previous theme.
    let onClose: (_ restorePreviewTheme: Bool) -> Void
    /// Live preview for sidebar hosts. Initial setup does not call this because
    /// the host already inherits the active Space theme; subsequent user theme
    /// selections and slider adjustments do.
    var onThemeSelectionChange: ((Theme) -> Void)? = nil
    /// Lets sidebar hosts restore the source Space's real theme only after the
    /// target Space has surfaced, or immediately when activation fails.
    var onCreatedSpaceActivationFinished: (() -> Void)? = nil
    /// Live icon mirror for sidebar hosts: fired with the seeded random icon
    /// on appear and on every later pick, so the Spaces strip's dashed
    /// placeholder pip previews the new Space's icon. Nil for the standalone
    /// window, which shows no strip.
    var onIconSelectionChange: ((IconPickerSelection) -> Void)? = nil

    @State private var name: String = ""
    /// Icon/emoji pinned to the new Space, chosen from the same picker the
    /// Spaces settings pane uses. Defaults to the picker's first Phi icon.
    @State private var selectedIcon: IconPickerSelection = .defaultSelection
    @State private var selectedProfileId: String = ""
    /// Theme pinned to the new Space. Every Space owns a theme — there is no
    /// "follow global" anymore. Seeded with a random theme distinct from the
    /// source Space's on appear; nil only before that (falls back to the
    /// inherited `initialThemeId`).
    @State private var selectedThemeId: String?
    /// Theme-component slider position. Follows the selected theme's
    /// saturation (or Pure brightness) until the user drags it; from then on
    /// it's a deliberate choice that survives theme switches and is persisted
    /// on the new Space.
    @State private var themeSliderValue: Double = 50
    @State private var userAdjustedThemeComponent = false
    @FocusState private var nameFocused: Bool

    @Environment(\.phiAppearance) private var appearance

    var body: some View {
        styledContent
            .onAppear {
                selectedProfileId = resolvedInitialProfileId
                // Give every new Space a fresh random look out of the box — a
                // random Phi icon and a random theme, always distinct from the
                // source Space's, so Spaces remain visually distinct and the
                // sidebar form arrives reading as a NEW Space instead of a
                // re-dress of the current one.
                selectedIcon = .phiIcon(id: PhiIconCatalog.allIds.randomElement() ?? PhiIconCatalog.allIds[0])
                if let freshTheme = Theme.builtInThemes
                    .filter({ $0.id != resolvedInitialThemeId })
                    .randomElement() {
                    selectedThemeId = freshTheme.id
                }
                syncThemeSliderToSelectedTheme()
                // Preview immediately so the swipe-in surface already carries
                // the new Space's color (sidebar hosts only; the standalone
                // window has no live preview and just shows the selection).
                if selectedThemeId != nil {
                    onThemeSelectionChange?(effectiveTheme())
                }
                onIconSelectionChange?(selectedIcon)
                DispatchQueue.main.async { nameFocused = true }
            }
            .onChange(of: selectedIcon.storageValue) { _ in
                onIconSelectionChange?(selectedIcon)
            }
    }

    @ViewBuilder
    private var styledContent: some View {
        switch style {
        case .window:
            formStack
                .padding(.horizontal, 20)
                .padding(.vertical, 24)
                .frame(width: formMaxWidth + 40)
        case .sidebar:
            // Transparent so the themed visual-effect backdrop installed by
            // `SidebarViewController.showCreateSpaceOverlay` shows through —
            // the form then sits on the active Space's overlay color and
            // opacity instead of an opaque card that ignores the Space theme.
            // Vertically centered when the form is shorter than the sidebar, but
            // still scrolls when the embedded icon grid makes it taller than a
            // short sidebar so the create button stays reachable: pinning a
            // `minHeight` of the container expands the content frame to the
            // sidebar height (SwiftUI centers within it by default) while letting
            // it grow past that height to drive the ScrollView.
            //
            // A vertical ScrollView proposes its content's *ideal* width rather
            // than its own, so the bounded column renders at full width and
            // clips in a narrow sidebar — and never reflows when the divider is
            // dragged. Read the live container width from an outer GeometryReader
            // (which tracks the hosting view's bounds across resizes) and pin the
            // scroll content to it so the form follows the sidebar width.
            GeometryReader { geo in
                ScrollView {
                    formStack
                        .padding(.horizontal, 10)
                        .padding(.vertical, 20)
                        .frame(width: geo.size.width)
                        .frame(minHeight: geo.size.height)
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .contentShape(Rectangle())
            }
        }
    }

    private var formStack: some View {
        VStack(spacing: 28) {
            header
            form
            actions
        }
        // One bounded, centered column so every element shares a width and the
        // form never stretches across a wide sidebar. In a narrower sidebar it
        // shrinks to fit; the icon grid reflows to match.
        .frame(maxWidth: formMaxWidth)
    }

    /// Bounded column width. The floating popup uses a comfortable dialog width;
    /// the sidebar overlay fills the sidebar (minus its slim padding) up to the
    /// same width, so only an unusually wide sidebar leaves margins.
    private var formMaxWidth: CGFloat {
        style == .window ? Self.windowContentWidth : Self.sidebarContentWidth
    }

    private static let sidebarContentWidth: CGFloat = 320
    private static let windowContentWidth: CGFloat = 280

    // MARK: - Sections

    private var header: some View {
        VStack(spacing: 12) {
            Text(NSLocalizedString("sidebar.createSpace.title", value: "Create a Space",
                comment: "Title of the create-Space panel"))
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Color.primary.opacity(0.85))
            Text(NSLocalizedString("sidebar.createSpace.subtitle", value: "Each space has its own independent bookmarks",
                comment: "Subtitle of the create-Space panel"))
                .font(.system(size: 14))
                .foregroundStyle(Color.primary.opacity(0.5))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var form: some View {
        VStack(spacing: 4) {
            nameField
            profileRow
            iconBlock
            colorBlock
        }
    }

    /// Inline icon/emoji picker, mirroring the Spaces settings pane so creating a
    /// Space offers the same chooser as editing one. A greedy `GeometryReader`
    /// reports the real column width so the picker fills it exactly (a plain
    /// `.frame(maxWidth:.infinity)` leaves the adaptive grid at its 1-column
    /// minimum, centered).
    private var iconBlock: some View {
        GeometryReader { geo in
            IconPicker(
                selected: selectedIcon,
                showsGroups: true,
                width: geo.size.width,
                onSelect: { selectedIcon = $0 }
            )
        }
        .frame(height: IconPicker.preferredHeight)
        .padding(.vertical, 2)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var nameField: some View {
        TextField(
            NSLocalizedString("sidebar.createSpace.nameField.placeholder", value: "Space name", comment: "Placeholder for the Space-name field"),
            text: $name
        )
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .focused($nameFocused)
            .onSubmit(create)
            .frame(height: 32)
            .padding(.horizontal, 8)
            .background(Color.primary.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var profileRow: some View {
        HStack(spacing: 8) {
            Text(NSLocalizedString("sidebar.createSpace.profilePicker.label", value: "Profile",
                comment: "Label for the profile picker in the create-Space panel"))
                .font(.system(size: 13))
                .foregroundStyle(Color.primary.opacity(0.85))
            Spacer(minLength: 0)
            profilePill
        }
        .frame(height: 32)
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var profilePill: some View {
        Menu {
            ForEach(profileManager.userAssignableProfiles, id: \.profileId) { profile in
                Button(profile.displayName) { selectedProfileId = profile.profileId }
            }
            Divider()
            Button {
                promptCreateProfile()
            } label: {
                Label(NSLocalizedString("sidebar.createSpace.profilePicker.newProfileAction", value: "New Profile\u{2026}",
                    comment: "Profile picker item to create a new profile"),
                    systemImage: "plus")
            }
        } label: {
            HStack(spacing: 4) {
                Text(selectedProfileName)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.primary.opacity(0.85))
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(0.5))
            }
            .padding(.leading, 12)
            .padding(.trailing, 8)
            .frame(height: 20)
            .background(Color.primary.opacity(0.06))
            .clipShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    /// Color + theme-component chooser matching the Spaces settings card: one
    /// row of theme dots (selected one ringed), a divider, then the saturation
    /// or Pure-brightness slider. Dots spread evenly across the bounded column
    /// and shrink with the sidebar.
    private var colorBlock: some View {
        VStack(spacing: 12) {
            HStack(spacing: 0) {
                ForEach(Theme.builtInThemes, id: \.id) { theme in
                    ThemeSwatchView(
                        fillColor: theme == .pure
                            ? .white
                            : Color(theme.color(for: .themeColor, appearance: appearance)),
                        ringColor: Color(theme.color(for: .themeColor, appearance: appearance)),
                        selected: effectiveThemeId == theme.id,
                        title: nil,
                        showsContrastBorder: theme == .pure,
                        dotDiameter: 16,
                        ringDiameter: 20,
                        action: { selectTheme(theme.id) }
                    )
                    .help(theme.name)
                    .frame(maxWidth: .infinity)
                }
            }

            Divider()

            // The slider follows the live column width (the sidebar overlay
            // shrinks with the sidebar), so read it from a GeometryReader
            // rather than fixing a width.
            GeometryReader { geo in
                ThemeOpacitySliderView(
                    value: themeSliderBinding,
                    trackColor: effectiveTheme().color(for: .windowOverlayBackground, appearance: appearance),
                    borderColor: ThemedColor.border.resolve(theme: effectiveTheme(), appearance: appearance),
                    trackStyle: effectiveThemeId == Theme.pure.id
                        ? .pureBrightness(appearance)
                        : .saturation,
                    width: geo.size.width
                )
            }
            .frame(height: 20)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 12)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var themeSliderBinding: Binding<Double> {
        Binding(
            get: { themeSliderValue },
            set: { newValue in
                themeSliderValue = newValue
                userAdjustedThemeComponent = true
                onThemeSelectionChange?(effectiveTheme())
            }
        )
    }

    private func selectTheme(_ themeId: String) {
        guard effectiveThemeId != themeId else { return }
        selectedThemeId = themeId
        if !userAdjustedThemeComponent {
            syncThemeSliderToSelectedTheme()
        }
        onThemeSelectionChange?(effectiveTheme())
    }

    /// Snaps the slider to the selected theme's own saturation or Pure
    /// brightness — the value the new Space inherits unless the user drags.
    private func syncThemeSliderToSelectedTheme() {
        let theme = selectedBaseTheme()
        if theme.id == Theme.pure.id {
            let brightness = theme
                .color(for: .windowOverlayBackground, appearance: appearance)
                .hsbBrightnessComponent
            themeSliderValue = PureThemeBrightnessScale.sliderValue(
                forBrightness: Double(brightness),
                appearance: appearance
            )
        } else {
            let saturation = theme
                .color(for: .windowOverlayBackground, appearance: appearance)
                .hsbSaturationComponent
            themeSliderValue = OverlaySaturationScale.sliderValue(
                forSaturation: Double(saturation)
            )
        }
    }

    private var actions: some View {
        VStack(spacing: 12) {
            Button(action: create) {
                Text(NSLocalizedString("sidebar.createSpace.createButton", value: "Create Space",
                    comment: "Confirm button in the create-Space panel"))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.95))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .background(selectedThemeColor)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)

            Button {
                onClose(true)
            } label: {
                Text(NSLocalizedString("sidebar.createSpace.cancelButton", value: "Cancel", comment: "Cancel button"))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(0.85))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
        }
    }

    // MARK: - Color math

    /// The theme id used to resolve the swatch fill, caption, and derived
    /// `colorHex`.
    private var effectiveThemeId: String {
        selectedThemeId ?? resolvedInitialThemeId
    }

    private var resolvedInitialThemeId: String {
        ThemeManager.shared.registeredThemes[initialThemeId]?.id
            ?? Theme.builtInThemes.first(where: { $0.id == initialThemeId })?.id
            ?? ThemeManager.shared.currentTheme.id
    }

    /// The create action follows the theme currently selected for the new Space.
    private var selectedThemeColor: Color {
        Color(effectiveTheme().color(for: .themeColor, appearance: appearance))
    }

    /// The Space's stored `colorHex` (which drives the sidebar tint) is derived
    /// from the resolved theme's overlay color, so the tint matches the Space's
    /// pinned theme.
    private func resolvedColorHex() -> String {
        effectiveTheme().color(for: .windowOverlayBackground, appearance: appearance).hexRGBString
    }

    private func selectedBaseTheme() -> Theme {
        ThemeManager.shared.registeredThemes[effectiveThemeId]
            ?? Theme.builtInThemes.first(where: { $0.id == effectiveThemeId })
            ?? ThemeManager.shared.currentTheme
    }

    /// The theme backing the new Space: the selected theme, with the user's
    /// custom saturation or Pure brightness applied on a palette copy once
    /// the slider has been touched, matching the theme that will be persisted.
    private func effectiveTheme() -> Theme {
        let base = selectedBaseTheme()
        guard userAdjustedThemeComponent else { return base }
        if base.id == Theme.pure.id {
            return ThemeColorAdjustment.applyingPureBrightness(
                sliderValue: themeSliderValue,
                to: base
            )
        }

        let saturation = CGFloat(
            OverlaySaturationScale.saturation(forSlider: themeSliderValue)
        )
        return ThemeColorAdjustment.applyingSaturation(
            light: appearance.isLight ? saturation : nil,
            dark: appearance.isDark ? saturation : nil,
            darkWindowBackground: appearance.isDark ? saturation : nil,
            to: base
        )
    }

    // MARK: - Profiles

    private var resolvedInitialProfileId: String {
        if let id = initialProfileId,
           profileManager.userAssignableProfiles.contains(where: { $0.profileId == id }) {
            return id
        }
        return profileManager.userAssignableProfiles.first?.profileId ?? LocalStore.defaultProfileId
    }

    private var selectedProfileName: String {
        profileManager.profile(for: selectedProfileId)?.displayName ?? selectedProfileId
    }

    /// Prompts for a name and creates a new profile, selecting it for this
    /// Space once the bridge reports the new id. Mirrors the menu's
    /// `newProfile` flow so both entry points behave identically.
    private func promptCreateProfile() {
        guard let name = ProfileNameFieldValidator.present(.create) else { return }
        profileManager.createProfile(displayName: name) { newId in
            if let newId { selectedProfileId = newId }
        }
    }

    // MARK: - Commit

    private func create() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmed.isEmpty
            ? String(format: NSLocalizedString("sidebar.createSpace.defaultName", value: "Space %d",
                comment: "Default name for a newly created Space"),
                manager.spaces.count + 1)
            : trimmed
        let profileId = selectedProfileId.isEmpty ? resolvedInitialProfileId : selectedProfileId
        let newSpaceId = manager.createSpace(
            name: finalName,
            colorHex: resolvedColorHex(),
            iconName: selectedIcon.storageValue,
            profileId: profileId
        )
        if newSpaceId != nil {
            PostHogSDK.shared.capture("space_created", properties: [
                "total_spaces": manager.spaces.count,
                "non_default_profile": profileId != LocalStore.defaultProfileId,
            ])
            FirstTimeActionTracker.capture(.spaceCreated)
        }
        // Pin the chosen theme (and, when the user touched the slider, its
        // custom saturation or Pure brightness) to the new Space. Persisted
        // now; applied when its window spawns in activateInFocusedWindow.
        if let newSpaceId {
            manager.setTheme(forSpaceId: newSpaceId, themeId: effectiveThemeId)
            if userAdjustedThemeComponent {
                if effectiveThemeId == Theme.pure.id {
                    manager.setPureThemeSliderValue(
                        themeSliderValue,
                        forSpaceId: newSpaceId
                    )
                } else {
                    manager.setOverlaySaturation(
                        CGFloat(
                            OverlaySaturationScale.saturation(
                                forSlider: themeSliderValue
                            )
                        ),
                        forSpaceId: newSpaceId,
                        appearance: appearance
                    )
                }
            }
        }
        // A successful create keeps the selected live preview visible while
        // the new Space activates. Failure follows the ordinary close path and
        // restores the theme from before the panel opened.
        onClose(newSpaceId == nil)
        // Bring the freshly created Space to the front of the active window.
        // `createSpace` only records it as the persisted default, so without
        // this the current window would stay on the Space we created from — in
        // both the sidebar (vertical) and floating-panel (horizontal) flows.
        // Runs after `onClose` so the overlay / panel is torn down first and the
        // switch animation plays over the revealed sidebar rather than under it.
        if let newSpaceId {
            manager.activateInFocusedWindow(
                spaceId: newSpaceId,
                // The sidebar flow already presented the form as the new
                // Space — swipe-in arrival, previewed theme, placeholder pip
                // — so a second swipe into the spawned window would replay a
                // transition the user has already seen: present instantly.
                // The standalone-window flow had no such presentation and
                // keeps its slide.
                animated: style == .window,
                onActivationFailed: onCreatedSpaceActivationFinished,
                onSwapSettled: onCreatedSpaceActivationFinished
            )
        }
    }
}

// MARK: - Presentation

extension CreateSpacePanel {
    private static let windowIdentifier = "Phi Create Space"

    /// Single entry point for "New Space" from the menu or the Spaces picker.
    /// Vertical layouts (Performance / Balanced) show the form inline in the
    /// sidebar surface — the docked sidebar, or the floating panel while the
    /// sidebar is collapsed and the panel is up. The horizontal layout
    /// (Comfortable) — or any window without a usable sidebar surface —
    /// falls back to the standalone window.
    static func requestCreation(initialProfileId: String?) {
        if let wc = MainBrowserWindowControllersManager.shared.activeWindowController,
           !wc.browserState.layoutMode.isTraditional {
            if !wc.browserState.sidebarCollapsed {
                let sidebar = wc.mainSplitViewController.sidebarViewController
                if sidebar.isViewLoaded, sidebar.view.window != nil, sidebar.view.bounds.width > 120 {
                    sidebar.showCreateSpaceOverlay(initialProfileId: initialProfileId)
                    return
                }
            } else {
                // Collapsed sidebar: the docked sidebar still passes
                // window/width checks (the split item keeps the view parked
                // at its last width), but it's invisible — the form must not
                // mount there. The floating panel is the sidebar surface
                // then: host the form inline in the open panel (which pins
                // itself open while the form is up). No open panel — e.g.
                // the menu's "New Space" without hovering — falls through
                // to the standalone window.
                let webContent = wc.mainSplitViewController.webContentContainerViewController
                if let floating = webContent.floatingSidebarViewController,
                   webContent.floatingSidebarContainerView?.isHidden == false,
                   floating.isViewLoaded, floating.view.bounds.width > 120 {
                    floating.showCreateSpaceOverlay(initialProfileId: initialProfileId)
                    return
                }
            }
        }
        present(manager: .shared, initialProfileId: initialProfileId)
    }

    /// Brings up the create-Space panel in a single shared, chrome-light
    /// window. Reuses an already-open window so repeated invocations from the
    /// menu or the picker don't stack duplicates.
    @discardableResult
    static func present(manager: SpaceManager,
                        profileManager: ProfileManager = .shared,
                        initialProfileId: String?) -> NSWindow {
        if let existing = NSApp.windows.first(where: {
            $0.identifier?.rawValue == windowIdentifier
        }) {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return existing
        }

        let window = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier(windowIdentifier)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true

        let panel = CreateSpacePanel(
            manager: manager,
            profileManager: profileManager,
            initialProfileId: initialProfileId,
            initialThemeId: manager.activeSpaceId.map {
                manager.resolvedThemeId(forSpaceId: $0)
            } ?? ThemeManager.shared.currentTheme.id
        ) { [weak window] _ in
            window?.close()
        }
        let hosting = ThemedHostingController(rootView: panel)
        window.contentViewController = hosting
        window.setContentSize(hosting.view.fittingSize)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return window
    }
}

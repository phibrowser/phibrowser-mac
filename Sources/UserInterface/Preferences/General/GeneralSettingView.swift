// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import SwiftUI

enum NewTabBehaviour: String, CaseIterable, Identifiable {
    case newTabPage
    case omnibox
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .newTabPage:
            return NSLocalizedString("settings.general.newTabShortcut.newTabPageOption", value: "New Tab Page", comment: "General settings - Option to open New Tab Page when pressing ⌘+T")
        case .omnibox:
            return NSLocalizedString("settings.general.newTabShortcut.addressBarOption", value: "Omnibox", comment: "General settings - Option to open Omnibox search when pressing ⌘+T")
        }
    }
}

struct GeneralSettingView: View {
    @ObservedObject private var settingsPresentation = SettingsPresentationState.shared

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 24) {
                if !settingsPresentation.openedFromIncognito {
                    ThemeSectionView()
                }
                AppearanceSectionView()
                BrowsingSectionView()
                ProfileSectionView()
                DeveloperModeSectionView()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 36)
            .padding(.horizontal, 36)
        }
        .themedBackground(PhiPreferences.fixedWindowBackground)
        .frame(width: 680, height: 561)
    }
}

private struct ThemeSectionView: View {
    @ObservedObject private var spaceManager = SpaceManager.shared

    @State private var selectedThemeId: String = ThemeManager.shared.currentTheme.id
    @State private var sliderValue: Double = {
        let manager = ThemeManager.shared
        let overlayColor = manager.currentTheme.color(
            for: .windowOverlayBackground,
            appearance: manager.currentAppearance
        )
        if manager.currentTheme.id == Theme.pure.id {
            return PureThemeBrightnessScale.sliderValue(
                forBrightness: Double(overlayColor.hsbBrightnessComponent),
                appearance: manager.currentAppearance
            )
        }
        return OverlaySaturationScale.sliderValue(
            forSaturation: Double(overlayColor.hsbSaturationComponent)
        )
    }()

    @AppStorage(PhiPreferences.ThemeSettings.selectionTintEnabled.rawValue)
    private var selectionTintEnabled: Bool = true

    @Environment(\.phiAppearance) private var appearance

    private var themes: [Theme] {
        ThemeManager.shared.orderedThemes
    }

    private var selectedTheme: Theme {
        themes.first(where: { $0.id == selectedThemeId }) ?? ThemeManager.shared.currentTheme
    }

    private var sliderTrackColor: NSColor {
        selectedTheme.color(for: .windowOverlayBackground, appearance: appearance)
    }

    private var sliderBorderColor: NSColor {
        ThemedColor.border.resolve(theme: selectedTheme, appearance: appearance)
    }

    private var usesBrightnessControl: Bool {
        selectedThemeId == Theme.pure.id
    }

    private var sliderTrackStyle: ThemeSliderTrackStyle {
        usesBrightnessControl ? .pureBrightness(appearance) : .saturation
    }

    /// These controls edit the DEFAULT Space. With a single Space that is
    /// the whole browser; once more Spaces exist, each one carries its own
    /// color adjustment, so the rows lock and defer to the Spaces pane.
    private var themeEditingLocked: Bool {
        spaceManager.userSpaces.count > 1
    }

    var body: some View {
        GeneralSectionView(title: NSLocalizedString("settings.general.theme.sectionTitle", value: "Theme", comment: "General settings - Theme section title")) {
            GeneralContainerView {
                VStack(spacing: 0) {
                    Group {
                        HStack(alignment: .top, spacing: 12) {
                            Text(NSLocalizedString("settings.general.theme.colorTitle", value: "Color", comment: "General settings - Theme color row title"))
                                .font(.system(size: 13))
                                .themedForeground(.textPrimary)

                            Spacer(minLength: 12)

                            HStack(alignment: .top, spacing: 13) {
                                ForEach(themes, id: \.id) { theme in
                                    ThemeColorItemView(
                                        theme: theme,
                                        selected: selectedThemeId == theme.id,
                                        action: { selectTheme(theme) }
                                    )
                                }
                            }
                        }
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)

                        Divider()
                        
                        GeneralRowView(title: NSLocalizedString("settings.general.theme.opacityTitle", value: "Saturation", comment: "General settings - Theme saturation row title for adjusting the selected theme overlay color")) {
                            ThemeOpacitySliderView(
                                value: Binding(
                                    get: { sliderValue },
                                    set: { newValue in
                                        sliderValue = newValue
                                        handleSliderValueChanged(newValue)
                                    }
                                ),
                                trackColor: sliderTrackColor,
                                borderColor: sliderBorderColor,
                                trackStyle: sliderTrackStyle
                            )
                            .frame(width: 324, height: 20)
                        }
                    }
                    .disabled(themeEditingLocked)
                    .opacity(themeEditingLocked ? 0.4 : 1.0)

                    if themeEditingLocked {
                        Divider()
                        editInSpacesHintRow
                    }

                    Divider()

                    GeneralRowView(title: NSLocalizedString("settings.general.theme.webSelectionTintToggle", value: "Apply theme to text selection on web pages", comment: "General settings - Toggle title for tinting ::selection on third-party pages with the window theme accent")) {
                        Toggle("", isOn: $selectionTintEnabled)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            .themedTint(.themeColor)
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .themeDidChange)) { _ in
            syncThemeControls()
        }
        .onReceive(NotificationCenter.default.publisher(for: .appearanceDidChange)) { _ in
            syncSliderValue()
        }
        .onReceive(NotificationCenter.default.publisher(for: .spaceThemeDidChange)) { _ in
            syncThemeControls()
        }
        .onAppear {
            syncThemeControls()
        }
    }

    /// Shown while the theme rows are locked: says why and jumps
    /// to the pane where per-Space themes are edited.
    private var editInSpacesHintRow: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(NSLocalizedString("settings.general.theme.perSpaceCustomizationHint", value: "You have more than one Space, so each Space sets its own color and opacity.", comment: "General settings - Hint shown when the theme color/opacity rows are locked because multiple Spaces exist"))
                .font(.system(size: 11))
                .themedForeground(.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            Button {
                AppController.shared?.showSettings(pane: .spaces)
            } label: {
                Text(NSLocalizedString("settings.general.pinnedTabScope.openSpacesSettingsLink", value: "Edit in Spaces settings\u{2026}", comment: "General settings - Link that jumps to the Spaces settings pane"))
                    .font(.system(size: 12))
                    .foregroundStyle(Color.accentColor)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func selectTheme(_ theme: Theme) {
        guard selectedThemeId != theme.id else { return }

        selectedThemeId = theme.id
        // This control edits the default Space; SpaceManager also switches
        // the global theme to it so non-browser chrome and pre-Space
        // fallbacks stay in step.
        SpaceManager.shared.setTheme(forSpaceId: LocalStore.defaultSpaceId, themeId: theme.id)
        syncSliderValue()
    }

    private func handleSliderValueChanged(_ newSliderValue: Double) {
        let appearance = ThemeManager.shared.currentAppearance
        let themeId = SpaceManager.shared.resolvedThemeId(forSpaceId: LocalStore.defaultSpaceId)
        if themeId == Theme.pure.id {
            SpaceManager.shared.setPureThemeSliderValue(
                newSliderValue,
                forSpaceId: LocalStore.defaultSpaceId
            )
        } else {
            let saturation = CGFloat(
                OverlaySaturationScale.saturation(forSlider: newSliderValue)
            )
            SpaceManager.shared.setOverlaySaturation(
                saturation,
                forSpaceId: LocalStore.defaultSpaceId,
                appearance: appearance
            )
        }
    }

    private func syncThemeControls() {
        selectedThemeId = SpaceManager.shared.resolvedThemeId(forSpaceId: LocalStore.defaultSpaceId)
        syncSliderValue()
    }

    private func syncSliderValue() {
        let appearance = ThemeManager.shared.currentAppearance
        let themeId = SpaceManager.shared.resolvedThemeId(forSpaceId: LocalStore.defaultSpaceId)
        let newSliderValue: Double
        if themeId == Theme.pure.id {
            newSliderValue = SpaceManager.shared.effectivePureThemeSliderValue(
                forSpaceId: LocalStore.defaultSpaceId,
                appearance: appearance
            )
        } else {
            let saturation = SpaceManager.shared.effectiveOverlaySaturation(
                forSpaceId: LocalStore.defaultSpaceId,
                appearance: appearance
            )
            newSliderValue = OverlaySaturationScale.sliderValue(
                forSaturation: Double(saturation)
            )
        }
        sliderValue = newSliderValue
    }
}

private struct AppearanceSectionView: View {
    @AppStorage(PhiPreferences.GeneralSettings.layoutModeKey)
    private var layoutModeRawValue: String = PhiPreferences.GeneralSettings.loadLayoutMode().rawValue

    @State private var selectedAppearance: UserAppearanceChoice = ThemeManager.shared.userAppearanceChoice

    private var selectedLayoutMode: Binding<LayoutMode> {
        Binding(
            get: { LayoutMode(rawValue: layoutModeRawValue) ?? PhiPreferences.GeneralSettings.loadLayoutMode() },
            set: { mode in
                layoutModeRawValue = mode.rawValue
                PhiPreferences.GeneralSettings.saveLayoutMode(mode)
            }
        )
    }

    var body: some View {
        GeneralSectionView(title: NSLocalizedString("settings.general.appearance.sectionTitle", value: "Appearance", comment: "General settings - Appearance section title")) {
            GeneralContainerView {
                GeneralRowView(title: NSLocalizedString("settings.general.layoutMode.title", value: "Layout mode", comment: "General settings - Layout mode row title"), alignment: .top) {
                    HStack(spacing: 16) {
                        ForEach(LayoutMode.allCases) { mode in
                            GeneralSttingCardView(
                                image: Image(layoutImageResource(for: mode)),
                                action: { selectedLayoutMode.wrappedValue = mode },
                                selected: selectedLayoutMode.wrappedValue == mode,
                                title: mode.displayName
                            )
                        }
                    }
                }

                Divider()

                GeneralRowView(title: NSLocalizedString("settings.general.appearance.title", value: "Color appearance", comment: "General settings - Color appearance row title"), alignment: .top) {
                    HStack(spacing: 16) {
                        ForEach(UserAppearanceChoice.allCases, id: \.self) { choice in
                            GeneralSttingCardView(
                                image: Image(appearanceImageName(for: choice)),
                                action: {
                                    selectedAppearance = choice
                                    ThemeManager.shared.setUserAppearanceChoice(choice)
                                },
                                selected: selectedAppearance == choice,
                                title: choice.localizedName
                            )
                        }
                    }
                }
            }
        }
    }

    private func layoutImageResource(for mode: LayoutMode) -> ImageResource {
        switch mode {
        case .performance:
            return .tabLayoutPerformance
        case .balanced:
            return .tabLayoutBalanced
        case .comfortable:
            return .tabLayoutComfortable
        }
    }

    private func appearanceImageName(for choice: UserAppearanceChoice) -> String {
        switch choice {
        case .system:
            return "appearance-system"
        case .light:
            return "appearance-light"
        case .dark:
            return "appearance-dark"
        }
    }
}

private struct BrowsingSectionView: View {
    @AppStorage(PhiPreferences.GeneralSettings.openNewTabPageOnCmdT.rawValue)
    private var openNewTabPageOnCmdT: Bool = PhiPreferences.GeneralSettings.openNewTabPageOnCmdT.defaultValue

    @AppStorage(PhiPreferences.GeneralSettings.alwaysShowURLPath.rawValue)
    private var alwaysShowURLPath: Bool = PhiPreferences.GeneralSettings.alwaysShowURLPath.defaultValue

    @AppStorage(PhiPreferences.AISettings.phiAIEnabled.rawValue)
    private var phiAIEnabled: Bool = PhiPreferences.AISettings.phiAIEnabled.defaultValue

    @AppStorage(PhiPreferences.GeneralSettings.autoPictureInPictureModeKey)
    private var autoPictureInPictureModeRawValue: String = PhiPreferences.GeneralSettings.loadAutoPictureInPictureMode().rawValue

    // Backed by Chromium local state through the bridge, not @AppStorage: the
    // cold-start path reads the same pref, so it is the single source of truth.
    @State private var restoreLastSessionEnabled = SessionRestorePreference.isEnabled

    private var restoreLastSessionHint: String {
        restoreLastSessionEnabled
            ? NSLocalizedString("Reopen your windows and tabs the next time you open Phi.", comment: "General settings - Hint shown when restore-last-session is on")
            : NSLocalizedString("Phi starts with a new window. Closing a window may sign you out of some sites.", comment: "General settings - Hint shown when restore-last-session is off, noting session cookies may be cleared when a window closes")
    }

    private var selectedBehavior: Binding<NewTabBehaviour> {
        Binding(
            get: { openNewTabPageOnCmdT ? .newTabPage : .omnibox },
            set: { openNewTabPageOnCmdT = ($0 == .newTabPage) }
        )
    }

    private var selectedAutoPipMode: Binding<AutoPictureInPictureMode> {
        Binding(
            get: {
                AutoPictureInPictureMode(rawValue: autoPictureInPictureModeRawValue)
                    ?? PhiPreferences.GeneralSettings.loadAutoPictureInPictureMode()
            },
            set: { mode in
                autoPictureInPictureModeRawValue = mode.rawValue
                PhiPreferences.GeneralSettings.saveAutoPictureInPictureMode(mode)
            }
        )
    }

    var body: some View {
        GeneralSectionView(title: NSLocalizedString("settings.general.browsing.sectionTitle", value: "Browsing", comment: "General settings - Browsing section title")) {
            VStack(alignment: .leading, spacing: 8) {
                GeneralContainerView {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(NSLocalizedString("settings.general.newTabShortcut.title", value: "New tab behavior", comment: "General settings - Row title for configuring new tab behavior"))
                                .font(.system(size: 13))
                                .themedForeground(.textPrimary)
                            if !phiAIEnabled {
                                Text(NSLocalizedString("settings.general.newTabPage.aiRequiredHint", value: "New Tab Page requires Phi AI to be enabled", comment: "General settings - Hint shown when Phi AI is disabled explaining New Tab Page requires it"))
                                    .font(.system(size: 11))
                                    .themedForeground(.textTertiary)
                            }
                        }
                        Spacer(minLength: 12)
                        HStack(spacing: 16) {
                            ForEach(NewTabBehaviour.allCases) { behavior in
                                GeneralSttingCardView(
                                    image: Image(newTabImageName(for: behavior)),
                                    action: {
                                        if behavior == .newTabPage && !phiAIEnabled { return }
                                        selectedBehavior.wrappedValue = behavior
                                    },
                                    selected: selectedBehavior.wrappedValue == behavior,
                                    title: behavior.displayName
                                )
                                .opacity(behavior == .newTabPage && !phiAIEnabled ? 0.4 : 1.0)
                            }
                        }
                    }
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Divider()

                    GeneralRowView(title: NSLocalizedString("settings.general.addressBar.showFullURLToggle", value: "Always show full URL", comment: "General settings - Toggle title for always showing full URL in address bar")) {
                        Toggle("", isOn: $alwaysShowURLPath)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            .themedTint(.themeColor)
                    }

                    Divider()

                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(NSLocalizedString("settings.general.pictureInPicture.title", value: "Auto picture-in-picture", comment: "General settings - Row title for the three-state auto picture-in-picture mode"))
                                .font(.system(size: 13))
                                .themedForeground(.textPrimary)
                            Text(autoPipModeHint(for: selectedAutoPipMode.wrappedValue))
                                .font(.system(size: 11))
                                .themedForeground(.textTertiary)
                        }
                        Spacer(minLength: 12)
                        Picker("", selection: selectedAutoPipMode) {
                            ForEach(AutoPictureInPictureMode.allCases) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .fixedSize()
                    }
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Divider()

                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(NSLocalizedString("Restore last session", comment: "General settings - Row title for the app-level restore-previous-session toggle"))
                                .font(.system(size: 13))
                                .themedForeground(.textPrimary)
                            Text(restoreLastSessionHint)
                                .font(.system(size: 11))
                                .themedForeground(.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 12)
                        Toggle("", isOn: $restoreLastSessionEnabled)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            .themedTint(.themeColor)
                    }
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onChange(of: restoreLastSessionEnabled) { _, newValue in
                        SessionRestorePreference.isEnabled = newValue
                    }

                    Divider()

                    Button(action: handleAdditionalBrowserSettingsTap) {
                        GeneralRowView(title: NSLocalizedString("settings.general.additionalBrowserSettings.title", value: "Additional browser settings", comment: "General settings - Title for always more settings")) {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .themedForeground(.textSecondary)
                        }
                        .contentShape(Rectangle())
                        .padding(.vertical, 2)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func newTabImageName(for behavior: NewTabBehaviour) -> String {
        switch behavior {
        case .newTabPage:
            return "newtab-ntp"
        case .omnibox:
            return "newtab-omibar"
        }
    }

    private func autoPipModeHint(for mode: AutoPictureInPictureMode) -> String {
        switch mode {
        case .off:
            return NSLocalizedString("settings.general.pictureInPicture.offDescription", value: "Never pop out automatically; manual picture-in-picture still works", comment: "General settings - Hint for the Off auto picture-in-picture mode")
        case .normal:
            return NSLocalizedString("settings.general.pictureInPicture.normalDescription", value: "Pop out playing video when you switch tabs or apps", comment: "General settings - Hint for the Normal auto picture-in-picture mode")
        case .parked:
            return NSLocalizedString("settings.general.pictureInPicture.parkAtEdgeDescription", value: "Pop out playing video, parked at the screen edge until you click it", comment: "General settings - Hint for the Park at edge auto picture-in-picture mode")
        }
    }

    private func handleAdditionalBrowserSettingsTap() {
        MainBrowserWindowControllersManager
            .shared
            .activeWindowController?
            .browserState
            .createTab("chrome://settings")
    }
}

/// The sole profile's browser settings, inlined so a single-profile user never
/// needs the Profiles pane. Mirrors the Theme section's per-Space behavior:
/// once more profiles exist each one carries its own settings, so the section
/// collapses to a hint that jumps to the Profiles pane.
private struct ProfileSectionView: View {
    @ObservedObject private var profileManager = ProfileManager.shared

    /// Counts only user-assignable profiles: the agent's auto-created fallback
    /// profile belongs to the agent and must not push a single-profile user
    /// into the "more than one profile" hint.
    private var hasMultipleProfiles: Bool {
        profileManager.userAssignableProfiles.count > 1
    }

    private var soleProfileId: String {
        profileManager.userAssignableProfiles.first?.profileId ?? LocalStore.defaultProfileId
    }

    var body: some View {
        GeneralSectionView(title: NSLocalizedString("settings.general.profile.sectionTitle", value: "Profile", comment: "General settings - Profile section title")) {
            if hasMultipleProfiles {
                GeneralContainerView {
                    editInProfilesHintRow
                }
            } else {
                ProfileDetailSettingsView(profileId: soleProfileId)
            }
        }
        .onAppear {
            profileManager.refresh()
        }
    }

    /// Shown instead of the inline settings once several profiles exist: says
    /// why and jumps to the pane where each profile is edited on its own.
    private var editInProfilesHintRow: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(NSLocalizedString("settings.general.profile.multipleProfilesHint", value: "You have more than one profile, so each profile manages its own settings.", comment: "General settings - Hint shown in place of the inline profile settings because multiple profiles exist"))
                .font(.system(size: 11))
                .themedForeground(.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            Button {
                AppController.shared?.showSettings(pane: .profiles)
            } label: {
                Text(NSLocalizedString("settings.general.profile.openProfilesSettingsLink", value: "Edit in Profiles settings\u{2026}", comment: "General settings - Link that jumps to the Profiles settings pane"))
                    .font(.system(size: 12))
                    .foregroundStyle(Color.accentColor)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The "Developer mode" master toggle. Turning it OFF is a kill-switch, not
/// just UI hiding: the Developer settings tab disappears and the features it
/// governs shut off with it — agent CDP access and the agent password manager
/// (see `AppController.setDeveloperModeEnabled`). Turning it back on reveals
/// the tab again but re-enables nothing automatically.
private struct DeveloperModeSectionView: View {
    @State private var developerModeEnabled = PhiPreferences.AgentSpaces.developerModeEnabled

    var body: some View {
        GeneralSectionView(title: NSLocalizedString("settings.general.developerMode.sectionTitle", value: "Developer", comment: "General settings - Developer section title")) {
            GeneralContainerView {
                GeneralRowView(title: NSLocalizedString("settings.general.developerMode.enableToggle", value: "Developer mode", comment: "General settings - Toggle title for developer mode; turning it off also disables agent access and the agent password manager")) {
                    Toggle("", isOn: $developerModeEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .themedTint(.themeColor)
                }

                Divider()
                hintRow
            }
        }
        .onChange(of: developerModeEnabled) { _, newValue in
            // Deferred: applying the change rebuilds the settings window,
            // which closes the window hosting this very view — that must not
            // happen mid view-update.
            DispatchQueue.main.async {
                AppController.shared?.setDeveloperModeEnabled(newValue)
            }
        }
    }

    private var hintRow: some View {
        Text(developerModeEnabled
            ? NSLocalizedString("settings.general.developerMode.enabledHint", value: "Agent access, permissions, and the password manager live in the Developer tab.", comment: "General settings - Hint under the developer mode toggle pointing at the Developer settings pane")
            : NSLocalizedString("settings.general.developerMode.disabledHint", value: "Turning developer mode off also turns off agent access and the agent password manager.", comment: "General settings - Hint under the developer mode toggle explaining the kill-switch behavior"))
            .font(.system(size: 11))
            .themedForeground(.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct GeneralSectionView<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.system(size: 12))
                .themedForeground(.textSecondary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct GeneralContainerView<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .padding(.horizontal, 12)
        .themedBackground(.settingItemBackground)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .themedStroke(.border)
        }
    }
}

private struct GeneralRowView<Accessory: View>: View {
    let title: String
    var alignment: VerticalAlignment = .center
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(alignment: alignment, spacing: 12) {
            Text(title)
                .font(.system(size: 13))
                .themedForeground(.textPrimary)
            Spacer(minLength: 12)
            accessory
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ThemeColorItemView: View {
    let theme: Theme
    let selected: Bool
    let action: () -> Void

    @Environment(\.phiAppearance) private var appearance

    private var swatchColor: Color {
        if theme == .pure {
            return .white
        }
        return Color(theme.color(for: .themeColor, appearance: appearance))
    }

    var body: some View {
        ThemeSwatchView(
            fillColor: swatchColor,
            ringColor: Color(theme.color(for: .themeColor, appearance: appearance)),
            selected: selected,
            title: theme.name,
            showsContrastBorder: theme == .pure,
            action: action
        )
        .frame(width: 30)
    }
}

#Preview {
    GeneralSettingView()
}

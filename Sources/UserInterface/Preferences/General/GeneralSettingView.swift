// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import PostHog
import SwiftUI

enum AppLanguageAnalytics {
    static func changeProperties(
        from oldValue: AppLanguagePreference,
        to newValue: AppLanguagePreference
    ) -> [String: String] {
        [
            "from": oldValue.storageValue,
            "to": newValue.storageValue,
        ]
    }
}

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
    /// Bumped when a companion app connects or quits. Reading it in `body`
    /// re-runs `body`, which re-reads Folio's flag.
    @State private var companionRevision = 0

    var body: some View {
        let _ = companionRevision
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 24) {
                LanguageSectionView()
                if !settingsPresentation.openedFromIncognito {
                    ThemeSectionView()
                }
                AppearanceSectionView()
                BrowsingSectionView()
                if SaveForLaterService.featureEnabled {
                    SaveForLaterSectionView()
                }
                ProfileSectionView()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 36)
            .padding(.horizontal, 36)
        }
        .themedBackground(PhiPreferences.fixedWindowBackground)
        .frame(width: 680, height: 561)
        // The Folio app connecting or quitting flips Folio while Settings is
        // open (see SaveForLaterService.featureEnabled).
        .onReceive(NotificationCenter.default.publisher(for: .agentCompanionsDidChange)) { _ in
            companionRevision += 1
        }
    }
}

private struct ThemeSectionView: View {
    @ObservedObject private var spaceManager = SpaceManager.shared

    @AppStorage(PhiPreferences.ThemeSettings.selectionTintEnabled.rawValue)
    private var selectionTintEnabled: Bool = true

    /// With multiple Spaces, edit each Space's colors in the Spaces pane.
    private var themeEditingLocked: Bool {
        spaceManager.userSpaces.count > 1
    }

    var body: some View {
        GeneralSectionView(title: NSLocalizedString("settings.general.theme.sectionTitle", value: "Theme", comment: "General settings - Theme section title")) {
            GeneralContainerView {
                VStack(spacing: 0) {
                    ThemeColorSettingsRow(
                        spaceId: spaceManager.currentDefaultSpaceId,
                        title: NSLocalizedString("settings.general.theme.colorTitle", value: "Color", comment: "General settings - Theme color row title")
                    )
                    .id(spaceManager.currentDefaultSpaceId)
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

private struct LanguageSectionView: View {
    @State private var selection = PhiPreferences.GeneralSettings.loadAppLanguagePreference()
    @State private var repairedStoredLanguage = false
    @State private var hasPreparedStoredLanguage = false

    private var requiresRelaunch: Bool {
        selection != PhiPreferences.GeneralSettings.appLanguagePreferenceAtLaunch
            || repairedStoredLanguage
    }

    var body: some View {
        GeneralSectionView(
            title: NSLocalizedString(
                "settings.general.language.sectionTitle",
                value: "Language",
                comment: "General settings - Language section title"
            )
        ) {
            GeneralContainerView {
                GeneralRowView(
                    title: NSLocalizedString(
                        "settings.general.language.displayLanguageTitle",
                        value: "Display language",
                        comment: "General settings - Row title for choosing Phi's native interface language"
                    )
                ) {
                    Picker("", selection: $selection) {
                        Text(
                            NSLocalizedString(
                                "settings.general.language.systemDefaultOption",
                                value: "System Default",
                                comment: "General settings - Language option that follows macOS, including its per-app language preference"
                            )
                        )
                        .tag(AppLanguagePreference.system)

                        Divider()

                        ForEach(SupportedAppLanguage.pickerOrder) { language in
                            Text(language.displayName)
                                .tag(AppLanguagePreference.language(language))
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }

                if requiresRelaunch {
                    Divider()

                    HStack(alignment: .center, spacing: 12) {
                        Text(
                            NSLocalizedString(
                                "settings.general.language.relaunchHint",
                                value: "Restart Phi to apply this language.",
                                comment: "General settings - Hint shown after changing the display language explaining that a restart is required"
                            )
                        )
                        .font(.system(size: 11))
                        .themedForeground(.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)

                        Spacer(minLength: 12)

                        Button(
                            NSLocalizedString(
                                "settings.general.language.restartButton",
                                value: "Restart Phi",
                                comment: "General settings - Button to restart Phi and apply the selected display language"
                            ),
                            action: promptToRestartApplication
                        )
                        .controlSize(.small)
                    }
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .onAppear {
            guard !hasPreparedStoredLanguage else { return }
            hasPreparedStoredLanguage = true
            repairedStoredLanguage = PhiPreferences.GeneralSettings.saveAppLanguagePreference(
                selection
            )
            if repairedStoredLanguage {
                SentinelLanguagePreferenceSync.publish(selection)
            }
        }
        .onChange(of: selection) { oldValue, newValue in
            guard oldValue != newValue else { return }
            PostHogSDK.shared.capture(
                "language_changed",
                properties: AppLanguageAnalytics.changeProperties(
                    from: oldValue,
                    to: newValue
                )
            )
            PhiPreferences.GeneralSettings.saveAppLanguagePreference(newValue)
            SentinelLanguagePreferenceSync.publish(newValue)
            if newValue != PhiPreferences.GeneralSettings.appLanguagePreferenceAtLaunch {
                promptToRestartApplication()
            }
        }
    }

    @MainActor
    private func promptToRestartApplication() {
        let configuration = PhiAlertAppKitConfiguration(
            title: NSLocalizedString(
                "settings.general.language.restartPrompt.title",
                value: "Restart Phi?",
                comment: "General settings - Confirmation title shown after selecting a display language that differs from the currently applied language"
            ),
            message: NSLocalizedString(
                "settings.general.language.restartPrompt.message",
                value: "The selected language will take effect after Phi restarts. Restart now?",
                comment: "General settings - Confirmation message explaining that the newly selected display language requires a restart"
            ),
            secondaryAction: PhiAlertAppKitAction(
                NSLocalizedString(
                    "settings.general.language.restartPrompt.notNowButton",
                    value: "Not Now",
                    comment: "General settings - Button that postpones restarting after changing the display language"
                ),
                response: .alertSecondButtonReturn
            ),
            primaryAction: PhiAlertAppKitAction(
                NSLocalizedString(
                    "settings.general.language.restartButton",
                    value: "Restart Phi",
                    comment: "General settings - Button to restart Phi and apply the selected display language"
                ),
                role: .primary,
                response: .alertFirstButtonReturn
            )
        )

        DispatchQueue.main.async {
            guard let sourceWindow = NSApp.keyWindow ?? NSApp.mainWindow,
                  sourceWindow.isVisible else { return }

            sourceWindow.presentPhiAlert(configuration) { response in
                guard response == .alertFirstButtonReturn else { return }
                AppController.relaunchPhiApplication()
            }
        }
    }
}

private struct BrowsingSectionView: View {
    @AppStorage(PhiPreferences.GeneralSettings.openNewTabPageOnCmdT.rawValue)
    private var openNewTabPageOnCmdT: Bool = PhiPreferences.GeneralSettings.openNewTabPageOnCmdT.defaultValue

    private var selectedBehavior: Binding<NewTabBehaviour> {
        Binding(
            get: { openNewTabPageOnCmdT ? .newTabPage : .omnibox },
            set: { openNewTabPageOnCmdT = ($0 == .newTabPage) }
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
                        }
                        Spacer(minLength: 12)
                        HStack(spacing: 16) {
                            ForEach(NewTabBehaviour.allCases) { behavior in
                                GeneralSttingCardView(
                                    image: Image(newTabImageName(for: behavior)),
                                    action: {
                                        selectedBehavior.wrappedValue = behavior
                                    },
                                    selected: selectedBehavior.wrappedValue == behavior,
                                    title: behavior.displayName
                                )
                            }
                        }
                    }
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
}

/// The sole profile's browser settings, inlined so a single-profile user never
/// needs the Profiles pane. Mirrors the Theme section's per-Space behavior:
/// once more profiles exist each one carries its own settings, so the section
/// collapses to a hint that jumps to the Profiles pane.
private struct SaveForLaterSectionView: View {
    @State private var folderPath: String = PhiPreferences.SaveForLater.globalFolderPath
    @State private var autoSaveOnSiteActions = PhiPreferences.SaveForLater.autoSaveOnSiteActions

    private var autoSaveBinding: Binding<Bool> {
        Binding(
            get: { autoSaveOnSiteActions },
            set: { newValue in
                autoSaveOnSiteActions = newValue
                PhiPreferences.SaveForLater.autoSaveOnSiteActions = newValue
                SaveForLaterService.broadcastArmedState()
            }
        )
    }

    var body: some View {
        GeneralSectionView(title: NSLocalizedString("settings.general.folio.sectionTitle", value: "Folio", comment: "General settings - Folio section title")) {
            VStack(alignment: .leading, spacing: 8) {
                GeneralContainerView {
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(NSLocalizedString("settings.general.folio.folderTitle", value: "Save pages to", comment: "General settings - Row title for the folder saved pages are written into"))
                                .font(.system(size: 13))
                                .themedForeground(.textPrimary)
                            Text(NSLocalizedString("settings.general.folio.folderHint", value: "Each save writes a markdown article and a webpage copy side by side. Profiles can override this folder in their own settings.", comment: "General settings - Hint under the Folio folder row describing the saved file pair and the per-profile override"))
                                .font(.system(size: 11))
                                .themedForeground(.textTertiary)
                        }
                        Spacer(minLength: 12)
                        Button {
                            chooseFolder()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "folder.fill")
                                    .font(.system(size: 12))
                                    .themedForeground(.textSecondary)
                                Text((folderPath as NSString).lastPathComponent)
                                    .font(.system(size: 13))
                                    .themedForeground(.textPrimary)
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color.primary.opacity(0.06))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    // The row exists only while the remote flag is on — the
                    // flag is the rollout gate and kill switch for the whole
                    // auto-trigger machinery.
                    if SaveForLaterService.autoTriggerFlagEnabled {
                        Divider()

                        HStack(alignment: .center, spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(NSLocalizedString("settings.general.folio.autoSaveToggle", value: "Save when you like or bookmark on supported sites", comment: "General settings - Toggle title for the site-action auto-save: liking or bookmarking on supported sites also saves the page"))
                                    .font(.system(size: 13))
                                    .themedForeground(.textPrimary)
                                Text(NSLocalizedString("settings.general.folio.autoSaveHint", value: "Liking a YouTube video or bookmarking on X, Reddit, or Stack Overflow also saves that page here. Everything stays on this Mac.", comment: "General settings - Hint under the site-action auto-save toggle naming the supported sites and the local-only behavior"))
                                    .font(.system(size: 11))
                                    .themedForeground(.textTertiary)
                                // The sites themselves are the extension's
                                // rules corpus, so the per-site switches
                                // live on its page; this is the way in.
                                Button(NSLocalizedString("settings.general.folio.autoSaveSites", value: "Choose sites…", comment: "General settings - Button under the site-action auto-save toggle that opens the page listing each supported site with its own switch")) {
                                    SaveForLaterService.openAutoSaveSites()
                                }
                                .buttonStyle(.link)
                                .font(.system(size: 11))
                                .disabled(!PhiPreferences.SaveForLater.autoSaveOnSiteActions)
                            }
                            Spacer(minLength: 12)
                            Toggle("", isOn: autoSaveBinding)
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .controlSize(.mini)
                                .themedTint(.themeColor)
                        }
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = NSLocalizedString("settings.general.folio.chooseButton", value: "Choose", comment: "General settings - Folio folder picker confirm button")
        panel.message = NSLocalizedString("settings.general.folio.pickerMessage", value: "Choose where saved pages are stored.", comment: "General settings - Folio folder picker message")
        panel.directoryURL = URL(fileURLWithPath: folderPath, isDirectory: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        PhiPreferences.SaveForLater.globalFolderPath = url.path
        folderPath = PhiPreferences.SaveForLater.globalFolderPath
    }
}

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
                ProfileDetailSettingsView(profileId: soleProfileId, showsFolioFolder: false)
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

#Preview {
    GeneralSettingView()
}

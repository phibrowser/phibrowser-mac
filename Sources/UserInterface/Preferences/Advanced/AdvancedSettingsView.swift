// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import SwiftUI

struct AdvancedSettingsView: View {
    @AppStorage(PhiPreferences.GeneralSettings.alwaysShowURLPath.rawValue)
    private var alwaysShowURLPath: Bool = PhiPreferences.GeneralSettings.alwaysShowURLPath.defaultValue

    @AppStorage(PhiPreferences.GeneralSettings.showTabPreviews.rawValue)
    private var showTabPreviews: Bool = PhiPreferences.GeneralSettings.showTabPreviews.defaultValue

    @AppStorage(PhiPreferences.GeneralSettings.showOpenTabIndicators.rawValue)
    private var showOpenTabIndicators = PhiPreferences.GeneralSettings.showOpenTabIndicators.defaultValue

    @AppStorage(PhiPreferences.GeneralSettings.dimUnloadedTabIcons.rawValue)
    private var dimUnloadedTabIcons = PhiPreferences.GeneralSettings.dimUnloadedTabIcons.defaultValue

    @AppStorage(PhiPreferences.GeneralSettings.shortHighlightLinksEnabled.rawValue)
    private var shortHighlightLinksEnabled: Bool = PhiPreferences.GeneralSettings.shortHighlightLinksEnabled.defaultValue

    @AppStorage(PhiPreferences.GeneralSettings.autoPictureInPictureModeKey)
    private var autoPictureInPictureModeRawValue: String = PhiPreferences.GeneralSettings.loadAutoPictureInPictureMode().rawValue

    // Backed by Chromium local state through the bridge, not @AppStorage: the
    // cold-start path reads the same pref, so it is the single source of truth.
    @State private var restoreLastSessionEnabled = SessionRestorePreference.isEnabled

    private var restoreLastSessionHint: String {
        restoreLastSessionEnabled
            ? NSLocalizedString("settings.advanced.restoreLastSession.enabledHint", value: "Reopen your windows and tabs the next time you open Phi.", comment: "Advanced settings - Hint shown when restore-last-session is on")
            : NSLocalizedString("settings.advanced.restoreLastSession.disabledHint", value: "Phi starts with a new window. Closing a window may sign you out of some sites.", comment: "Advanced settings - Hint shown when restore-last-session is off, noting session cookies may be cleared when a window closes")
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
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 24) {
                pageCard
                browsingCard
                DeveloperModeSectionView()
                additionalSettingsCard
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 36)
            .padding(.horizontal, 36)
        }
        .themedBackground(PhiPreferences.fixedWindowBackground)
        .frame(width: 680, height: 561)
    }

    private var pageCard: some View {
        SettingsDetailCard {
            SettingsDetailRow(NSLocalizedString("settings.advanced.addressBar.showFullURLToggle", value: "Always show full URL", comment: "Advanced settings - Toggle title for always showing full URL in address bar")) {
                Toggle("", isOn: $alwaysShowURLPath)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .themedTint(.themeColor)
            }

            Divider()

            SettingsDetailRow(NSLocalizedString("settings.advanced.tabPreview.showToggle", value: "Show a preview card when hovering over a tab", comment: "Advanced settings - Toggle title for showing custom preview cards when hovering over open tabs")) {
                Toggle("", isOn: $showTabPreviews)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .themedTint(.themeColor)
            }

            Divider()

            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(NSLocalizedString("settings.advanced.openTabIndicators.showToggle", value: "Show open tab indicators", comment: "Advanced settings - Toggle title for showing dots on inactive open pinned tabs and bookmarks"))
                        .font(.system(size: 13))
                        .themedForeground(.textPrimary)
                    Text(NSLocalizedString("settings.advanced.openTabIndicators.description", value: "Show a dot on inactive pinned tabs and bookmarks that are currently open.", comment: "Advanced settings - Explains which tabs and bookmarks display the open-state dot"))
                        .font(.system(size: 11))
                        .themedForeground(.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Toggle("", isOn: $showOpenTabIndicators)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .themedTint(.themeColor)
            }
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(NSLocalizedString("settings.advanced.unloadedTabIcons.dimToggle", value: "Dim unloaded tab icons", comment: "Advanced settings - Toggle title for dimming icons of tabs whose pages are unloaded from memory"))
                        .font(.system(size: 13))
                        .themedForeground(.textPrimary)
                    Text(NSLocalizedString("settings.advanced.unloadedTabIcons.description", value: "Dim tab icons when their pages are unloaded from memory.", comment: "Advanced settings - Explains icon dimming for tabs whose pages are unloaded from memory"))
                        .font(.system(size: 11))
                        .themedForeground(.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Toggle("", isOn: $dimUnloadedTabIcons)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .themedTint(.themeColor)
            }
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var browsingCard: some View {
        SettingsDetailCard {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(NSLocalizedString("settings.advanced.restoreLastSession.toggle", value: "Restore last session", comment: "Advanced settings - Row title for the app-level restore-previous-session toggle"))
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

            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(NSLocalizedString("settings.advanced.highlightLinks.useShortLinksToggle", value: "Shorten links to selected text", comment: "Advanced settings - Toggle that controls whether Copy Link to Highlight generates a short link"))
                        .font(.system(size: 13))
                        .themedForeground(.textPrimary)
                    Text(NSLocalizedString("settings.advanced.highlightLinks.shortLinksDescription", value: "Applies to “Copy Link to Highlight” in the right-click menu. Turn off to copy the full link.", comment: "Advanced settings - Explains where the short-link toggle applies and that disabling it copies the full link to the selected text"))
                        .font(.system(size: 11))
                        .themedForeground(.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Toggle("", isOn: $shortHighlightLinksEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .themedTint(.themeColor)
            }
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(NSLocalizedString("settings.advanced.pictureInPicture.title", value: "Auto picture-in-picture", comment: "Advanced settings - Row title for the three-state auto picture-in-picture mode"))
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
        }
    }

    private var additionalSettingsCard: some View {
        SettingsDetailCard {
            Button(action: handleAdditionalBrowserSettingsTap) {
                SettingsDetailRow(NSLocalizedString("settings.advanced.additionalBrowserSettings.title", value: "Additional browser settings", comment: "Advanced settings - Title for always more settings")) {
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

    private func autoPipModeHint(for mode: AutoPictureInPictureMode) -> String {
        switch mode {
        case .off:
            return NSLocalizedString("settings.advanced.pictureInPicture.offDescription", value: "Never pop out automatically; manual picture-in-picture still works", comment: "Advanced settings - Hint for the Off auto picture-in-picture mode")
        case .normal:
            return NSLocalizedString("settings.advanced.pictureInPicture.normalDescription", value: "Pop out playing video when you switch tabs or apps", comment: "Advanced settings - Hint for the Normal auto picture-in-picture mode")
        case .parked:
            return NSLocalizedString("settings.advanced.pictureInPicture.parkAtEdgeDescription", value: "Pop out playing video, parked at the screen edge until you click it", comment: "Advanced settings - Hint for the Park at edge auto picture-in-picture mode")
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

/// The "Developer mode" master toggle. Turning it OFF is a kill-switch, not
/// just UI hiding: the Developer settings tab disappears and the features it
/// governs shut off with it — agent CDP access and the agent password manager
/// (see `AppController.setDeveloperModeEnabled`). Turning it back on reveals
/// the tab again but re-enables nothing automatically.
private struct DeveloperModeSectionView: View {
    @State private var developerModeEnabled = PhiPreferences.AgentSpaces.developerModeEnabled

    var body: some View {
        SettingsDetailCard {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(NSLocalizedString("settings.advanced.developerMode.enableToggle", value: "Developer mode", comment: "Advanced settings - Toggle title for developer mode; turning it off also disables agent access and the agent password manager"))
                        .font(.system(size: 13))
                        .themedForeground(.textPrimary)
                    hintText
                }
                Spacer(minLength: 12)
                Toggle("", isOn: $developerModeEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .themedTint(.themeColor)
            }
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
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

    private var hintText: some View {
        Text(developerModeEnabled
            ? NSLocalizedString("settings.advanced.developerMode.enabledHint", value: "Agent access, permissions, and the password manager live in the Developer tab.", comment: "Advanced settings - Hint under the developer mode toggle pointing at the Developer settings pane")
            : NSLocalizedString("settings.advanced.developerMode.disabledHint", value: "Turning developer mode off turns off agent access and the agent password manager, and revokes every allowed agent and credential approval. An agent that connects later can ask you to turn it back on.", comment: "Advanced settings - Hint under the developer mode toggle explaining the kill-switch behavior, the revoked approvals, and that an agent may request it back"))
            .font(.system(size: 11))
            .themedForeground(.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

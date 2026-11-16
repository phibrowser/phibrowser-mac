// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Combine
import SwiftUI

struct NavigationsSettingsView: View {
    @AppStorage(PhiPreferences.GeneralSettings.openExternalLinksInKiosk.rawValue)
    private var openExternalLinksInKiosk: Bool = PhiPreferences.GeneralSettings.openExternalLinksInKiosk.defaultValue

    @AppStorage(PhiPreferences.GeneralSettings.openKioskOnCommandOptionClick.rawValue)
    private var openKioskOnCommandOptionClick: Bool = PhiPreferences.GeneralSettings.openKioskOnCommandOptionClick.defaultValue

    @AppStorage(PhiPreferences.GeneralSettings.openKioskWithGlobalShortcut.rawValue)
    private var openKioskWithGlobalShortcut: Bool = PhiPreferences.GeneralSettings.openKioskWithGlobalShortcut.defaultValue

    @AppStorage(PhiPreferences.GeneralSettings.peekViewEnabled.rawValue)
    private var peekViewEnabled: Bool = PhiPreferences.GeneralSettings.peekViewEnabled.defaultValue

    @AppStorage(PhiPreferences.GeneralSettings.autoPeekViewEnabled.rawValue)
    private var autoPeekViewEnabled: Bool = PhiPreferences.GeneralSettings.autoPeekViewEnabled.defaultValue

    @AppStorage(PhiPreferences.GeneralSettings.autoPeekSameSiteLinksEnabled.rawValue)
    private var autoPeekSameSiteLinksEnabled: Bool = PhiPreferences.GeneralSettings.autoPeekSameSiteLinksEnabled.defaultValue

    @AppStorage(PhiPreferences.GeneralSettings.peekPanelSizeKey)
    private var peekPanelSize: PeekPanelSize = .large

    @State private var kioskShortcutDescription =
        NavigationsSettingsView.currentKioskShortcutDescription
    @State private var kioskShortcutStatus = AppController.shared?.kioskGlobalShortcutStatus ?? .disabled

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 28) {
                NavigationsSettingsSection(
                    title: NSLocalizedString("settings.navigations.kiosk.sectionTitle", value: "Kiosk", comment: "Navigations settings - Kiosk section title"),
                    description: NSLocalizedString("settings.navigations.kiosk.sectionDescription", value: "Open links in a lightweight window, one page at a time.", comment: "Navigations settings - Description of Kiosk windows")
                ) {
                    SettingsDetailCard {
                        NavigationsSettingsToggleRow(
                            title: NSLocalizedString("settings.navigations.kiosk.externalLinks.title", value: "Open external links in Kiosk", comment: "Navigations settings - Toggle title for opening links from other apps in Kiosk windows"),
                            description: NSLocalizedString("settings.navigations.kiosk.externalLinks.description", value: "Links opened from other apps use a focused, single-page Kiosk window.", comment: "Navigations settings - Explanation of the external-links Kiosk toggle"),
                            isOn: $openExternalLinksInKiosk,
                            onChange: { AppController.shared?.setOpenExternalLinksInKioskEnabled($0) }
                        )

                        SettingsRowDivider()

                        NavigationsSettingsToggleRow(
                            title: Self.globalShortcutTitle(
                                shortcutDescription: kioskShortcutDescription
                            ),
                            description: Self.globalShortcutStatusDescription(kioskShortcutStatus),
                            isOn: $openKioskWithGlobalShortcut,
                            onChange: {
                                AppController.shared?
                                    .setOpenKioskWithGlobalShortcutEnabled($0)
                            }
                        )

                        SettingsRowDivider()

                        NavigationsSettingsToggleRow(
                            title: NSLocalizedString("settings.navigations.kiosk.commandOption.title", value: "Open Kiosk when clicking links with ⌘⌥ held", comment: "Navigations settings - Toggle title for opening clicked links in Kiosk while Command and Option are held"),
                            description: NSLocalizedString("settings.navigations.kiosk.commandOption.description", value: "Hold Command and Option while clicking a link to open it in a Kiosk window.", comment: "Navigations settings - Explanation of the Command-Option Kiosk toggle"),
                            isOn: $openKioskOnCommandOptionClick,
                            onChange: { AppController.shared?.setOpenKioskOnCommandOptionClickEnabled($0) }
                        )
                    }
                }

                NavigationsSettingsSection(
                    title: NSLocalizedString("settings.navigations.peek.sectionTitle", value: "Peek", comment: "Navigations settings - Peek section title"),
                    description: NSLocalizedString("settings.navigations.peek.sectionDescription", value: "Preview a link without opening it in a new tab.", comment: "Navigations settings - Description of the Peek feature")
                ) {
                    SettingsDetailCard {
                        NavigationsSettingsToggleRow(
                            title: NSLocalizedString("settings.navigations.peek.enableToggle.title", value: "Enable Peek View", comment: "Navigations settings - Toggle title for enabling Peek View"),
                            description: NSLocalizedString("settings.navigations.peek.enableToggle.description", value: "Shift-click a link, or choose “Open Link in Peek View”, to preview it in a floating panel over the page. Not available in the Comfortable layout.", comment: "Navigations settings - Explanation of the Peek View toggle"),
                            isOn: $peekViewEnabled,
                            onChange: { enabled in
                                PeekViewAnalytics.settingChanged(enabled: enabled)
                                // The automatic sub-toggle follows the master's
                                // transitions: enabling Peek View re-enables it,
                                // disabling Peek View switches it off.
                                autoPeekViewEnabled = enabled
                            }
                        )

                        SettingsRowDivider()

                        NavigationsSettingsToggleRow(
                            title: NSLocalizedString("settings.navigations.peek.autoToggle.title", value: "Automatically peek from pinned tabs and bookmarks", comment: "Navigations settings - Toggle title for automatically opening cross-site links from pinned tabs and bookmarks in Peek View"),
                            description: NSLocalizedString("settings.navigations.peek.autoToggle.description", value: "Links that leave a pinned tab’s or bookmark’s site open in a Peek panel instead of a new tab.", comment: "Navigations settings - Explanation of the automatic Peek View toggle for pinned tabs and bookmarks"),
                            isOn: $autoPeekViewEnabled,
                            onChange: { PeekViewAnalytics.autoSettingChanged(enabled: $0) }
                        )
                        .disabled(!peekViewEnabled)
                        .opacity(peekViewEnabled ? 1.0 : 0.4)

                        SettingsRowDivider()

                        NavigationsSettingsToggleRow(
                            title: NSLocalizedString("settings.navigations.peek.sameSiteToggle.title", value: "Also peek links to the same site", comment: "Navigations settings - Toggle title for also opening same-site new-tab links from pinned tabs and bookmarks in Peek View"),
                            description: NSLocalizedString("settings.navigations.peek.sameSiteToggle.description", value: "Links in a pinned tab or bookmark that would open a new tab open in a Peek panel, even when they stay on the same site.", comment: "Navigations settings - Explanation of the toggle that extends automatic Peek to same-site links that open a new tab"),
                            isOn: $autoPeekSameSiteLinksEnabled,
                            onChange: { _ in }
                        )
                        .disabled(!peekViewEnabled || !autoPeekViewEnabled)
                        .opacity(peekViewEnabled && autoPeekViewEnabled ? 1.0 : 0.4)

                        SettingsRowDivider()

                        HStack(alignment: .center, spacing: 12) {
                            Text(peekPanelSizeTitle)
                                .font(.system(size: 13))
                                .themedForeground(.textPrimary)
                            Spacer(minLength: 12)
                            Picker("", selection: $peekPanelSize) {
                                ForEach(PeekPanelSize.allCases) { size in
                                    Text(size.displayName).tag(size)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .fixedSize()
                            .accessibilityLabel(peekPanelSizeTitle)
                        }
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .disabled(!peekViewEnabled)
                        .opacity(peekViewEnabled ? 1.0 : 0.4)
                    }
                }

                NavigationsSettingsSection(
                    title: NSLocalizedString("settings.navigations.urlRules.sectionTitle", value: "URL Rules", comment: "Navigations settings - URL Rules section title")
                ) {
                    SettingsDetailCard {
                        Button {
                            AppController.shared?.openURLRulesEditor(nil)
                        } label: {
                            HStack(alignment: .center, spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(NSLocalizedString("settings.navigations.urlRules.openButton", value: "Manage URL Rules\u{2026}", comment: "Navigations settings - Title of the row that opens the URL Rules editor"))
                                        .font(.system(size: 13))
                                        .themedForeground(.textPrimary)
                                    Text(NSLocalizedString("settings.navigations.urlRules.sectionDescription", value: "Route matching domains or URLs to a Space, Incognito, or Kiosk.", comment: "Navigations settings - Description below the URL Rules editor row title"))
                                        .font(.system(size: 11))
                                        .themedForeground(.textTertiary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 12)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 11, weight: .semibold))
                                    .themedForeground(.textSecondary)
                            }
                            .padding(.vertical, 12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 36)
            .padding(.horizontal, 36)
        }
        .themedBackground(PhiPreferences.fixedWindowBackground)
        .frame(width: 680, height: 561)
        .onReceive(
            NotificationCenter.default.publisher(for: .shortcutsDidChange)
        ) { _ in
            kioskShortcutDescription = Self.currentKioskShortcutDescription
        }
        .onReceive(NotificationCenter.default.publisher(for: KioskGlobalShortcutRegistrar.statusDidChangeNotification)) { _ in
            kioskShortcutStatus = AppController.shared?.kioskGlobalShortcutStatus ?? .disabled
        }
        .onAppear {
            kioskShortcutDescription = Self.currentKioskShortcutDescription
            kioskShortcutStatus = AppController.shared?.kioskGlobalShortcutStatus ?? .disabled
        }
    }

    private var peekPanelSizeTitle: String {
        NSLocalizedString("settings.navigations.peek.size.title", value: "Peek panel size", comment: "Navigations settings - Row title for choosing how wide the Peek panel is over the page")
    }

    static func globalShortcutStatusDescription(_ status: KioskGlobalShortcutRegistrar.Status) -> String? {
        switch status {
        case .disabled: return nil
        case .registered:
            return NSLocalizedString("settings.navigations.kiosk.globalShortcut.registered", value: "This shortcut is available in other apps.", comment: "Navigations settings - Status shown after the global Kiosk shortcut is successfully registered")
        case .unassigned:
            return NSLocalizedString("settings.navigations.kiosk.globalShortcut.unassigned", value: "Assign a New Kiosk Window shortcut in Shortcuts.", comment: "Navigations settings - Status shown when global Kiosk activation is enabled but its shortcut is unassigned")
        case .unsupported:
            return NSLocalizedString("settings.navigations.kiosk.globalShortcut.unsupported", value: "This shortcut is not supported globally with the current keyboard layout. Choose another shortcut.", comment: "Navigations settings - Status shown when the assigned Kiosk shortcut cannot be registered with the current keyboard layout")
        case .failed:
            return NSLocalizedString("settings.navigations.kiosk.globalShortcut.failed", value: "The global shortcut is unavailable. Choose another shortcut, or turn this setting off and on to retry.", comment: "Navigations settings - Status shown after the system rejects a global shortcut operation, with recovery guidance")
        }
    }

    static func globalShortcutTitle(shortcutDescription: String) -> String {
        String(
            format: NSLocalizedString(
                "settings.navigations.kiosk.globalShortcut.title",
                value: "Open Kiosk when pressing %@ in any app",
                comment: "Navigations settings - Toggle title for enabling the system-wide Kiosk shortcut; %@ is replaced by the current New Kiosk Window shortcut"
            ),
            shortcutDescription
        )
    }

    private static var currentKioskShortcutDescription: String {
        Shortcuts.key(for: .PHI_NEW_KIOSK_WINDOW)?.displayString ?? "—"
    }
}

private struct NavigationsSettingsSection<Content: View>: View {
    let title: String
    var description: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 12))
                    .themedForeground(.textSecondary)
                if let description {
                    Text(description)
                        .font(.system(size: 11))
                        .themedForeground(.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct NavigationsSettingsToggleRow: View {
    let title: String
    let description: String?
    @Binding var isOn: Bool
    let onChange: (Bool) -> Void

    init(
        title: String,
        description: String? = nil,
        isOn: Binding<Bool>,
        onChange: @escaping (Bool) -> Void
    ) {
        self.title = title
        self.description = description
        self._isOn = isOn
        self.onChange = onChange
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 13))
                    .themedForeground(.textPrimary)
                if let description {
                    Text(description)
                        .font(.system(size: 11))
                        .themedForeground(.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .themedTint(.themeColor)
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: isOn) { _, newValue in
            onChange(newValue)
        }
    }
}

#Preview {
    NavigationsSettingsView()
}

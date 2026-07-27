// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import SwiftUI
import AppKit

/// One profile's browser settings: search engine, download location, a
/// password-manager row that shows each detected manager extension's icon and
/// offers to install one, and quick links into that profile's data & settings
/// pages. The detail column of the Profiles pane, and inlined by the General
/// pane while only one profile exists.
///
/// Owns its own detail state and reloads when `profileId` changes. The
/// per-profile settings round-trip to Chromium via `ProfileManager`'s bridge
/// accessors and may load the profile on first access.
struct ProfileDetailSettingsView: View {
    let profileId: String

    /// The profile whose data the state below belongs to. Async bridge
    /// completions compare against this (reads see the live value, unlike the
    /// captured `profileId` parameter) so a slow off-profile load can't
    /// clobber a newer selection.
    @State private var activeProfileId: String?
    @State private var searchEngines: [SearchEngineInfo] = []
    @State private var defaultEngineId: String = ""
    @State private var downloadPath: String = ""
    @State private var isLoadingDetail: Bool = false
    @State private var profileExtensions: [ProfileExtensionInfo] = []
    @State private var installingManagerIds: Set<String> = []

    private var profileManager: ProfileManager { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsDetailCard {
                SettingsDetailRow(NSLocalizedString("settings.profiles.details.searchEngineLabel", value: "Search engine", comment: "Profiles settings - search engine row label"),
                                  systemImage: "magnifyingglass") {
                    searchEngineControl
                }
                SettingsRowDivider()
                SettingsDetailRow(NSLocalizedString("settings.profiles.details.downloadLocationLabel", value: "Download location", comment: "Profiles settings - download location row label"),
                                  systemImage: "arrow.down.to.line") {
                    downloadLocationControl
                }
                SettingsRowDivider()
                SettingsDetailRow(NSLocalizedString("settings.profiles.details.passwordManagerLabel", value: "Password Manager", comment: "Profiles settings - password manager row label"),
                                  systemImage: "key.fill") {
                    installPasswordManagerMenu
                }
                if !detectedPasswordManagers.isEmpty || !installingPasswordManagers.isEmpty {
                    installedPasswordManagersLine
                }
            }
            dataAndSettingsSection
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            activeProfileId = profileId
            loadDetail(profileId)
        }
        .onChange(of: profileId) { newProfileId in
            activeProfileId = newProfileId
            // In-flight install spinners are per-profile UI state; dropping
            // them also stops their polls. The installs themselves keep
            // running and show up as detected rows on the next visit.
            installingManagerIds = []
            loadDetail(newProfileId)
        }
    }

    /// Uniform chrome for the detail card's trailing controls (search engine,
    /// download location, password-manager install): one fixed-width pill so
    /// the three read as a single aligned control column. Content lays out
    /// leading-to-trailing inside the fixed width — put a Spacer before any
    /// trailing chevron.
    private func trailingControlPill<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 6, content: content)
            .frame(width: Self.trailingPillInnerWidth)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.primary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private static let trailingPillInnerWidth: CGFloat = 110

    @ViewBuilder
    private var searchEngineControl: some View {
        if isLoadingDetail {
            ProgressView().controlSize(.small)
        } else if searchEngines.isEmpty {
            Text(NSLocalizedString("settings.profiles.searchEngine.unavailableStatus", value: "Unavailable", comment: "Profiles settings - search engine list unavailable"))
                .font(.system(size: 12))
                .themedForeground(.textSecondary)
        } else {
            // Custom pill matching the download-location control (and the Spaces
            // pane's themeControl) so the rows' selectors share one size,
            // style, and trailing edge instead of the native picker's taller,
            // differently-inset bezel.
            Menu {
                Picker("", selection: searchBinding) {
                    ForEach(searchEngines) { engine in
                        Text(engine.name).tag(engine.id)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                trailingControlPill {
                    Text(selectedEngineName)
                        .font(.system(size: 13))
                        .themedForeground(.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .medium))
                        .themedForeground(.textSecondary)
                }
            }
            // .button + .plain renders the label exactly as given (like the
            // download Button's pill); .borderlessButton would impose a native
            // popup look instead, dropping the pill and its trailing chevron.
            // It requires macOS 13, so macOS 12 gets the borderless fallback.
            .pillMenuStyle()
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    private var selectedEngineName: String {
        searchEngines.first(where: { $0.id == defaultEngineId })?.name ?? ""
    }

    @ViewBuilder
    private var downloadLocationControl: some View {
        if isLoadingDetail {
            ProgressView().controlSize(.small)
        } else {
            Button {
                chooseDownloadLocation()
            } label: {
                trailingControlPill {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 12))
                        .themedForeground(.textSecondary)
                    Text(downloadFolderName)
                        .font(.system(size: 13))
                        .themedForeground(.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(.plain)
        }
    }

    private var downloadFolderName: String {
        guard !downloadPath.isEmpty else {
            return NSLocalizedString("settings.profiles.downloadLocation.choosePlaceholder", value: "Choose…", comment: "Profiles settings - download location not set")
        }
        return (downloadPath as NSString).lastPathComponent
    }

    // MARK: - Your Data and Settings links

    private struct DataLink: Identifiable {
        let page: String
        let title: String
        let systemImage: String
        var id: String { page }
    }

    private var dataLinks: [DataLink] {
        [
            DataLink(page: "privacy",
                     title: NSLocalizedString("settings.profiles.dataLinks.privacyAndSecurity", value: "Privacy and Security", comment: "Profiles settings - data link to privacy settings"),
                     systemImage: "lock.shield"),
            DataLink(page: "passwords",
                     title: NSLocalizedString("settings.profiles.dataLinks.passwords", value: "Passwords", comment: "Profiles settings - data link to saved passwords"),
                     systemImage: "key"),
            DataLink(page: "payments",
                     title: NSLocalizedString("settings.profiles.dataLinks.paymentMethods", value: "Credit Cards", comment: "Profiles settings - data link to payment methods"),
                     systemImage: "creditcard"),
            DataLink(page: "notifications",
                     title: NSLocalizedString("settings.profiles.dataLinks.notifications", value: "Notifications", comment: "Profiles settings - data link to notification settings"),
                     systemImage: "bell"),
            DataLink(page: "clearBrowserData",
                     title: NSLocalizedString("settings.profiles.dataLinks.clearBrowsingData", value: "Clear Browsing Data", comment: "Profiles settings - data link to clear browsing data"),
                     systemImage: "trash"),
        ]
    }

    private var dataAndSettingsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(NSLocalizedString("settings.profiles.dataLinks.sectionTitle", value: "Your Data and Settings", comment: "Profiles settings - data & settings section header"))
                .font(.system(size: 12))
                .themedForeground(.textSecondary)
                .padding(.leading, 2)
            SettingsDetailCard {
                ForEach(Array(dataLinks.enumerated()), id: \.element.page) { index, link in
                    if index > 0 { SettingsRowDivider() }
                    dataLinkRow(link)
                }
            }
        }
    }

    private func dataLinkRow(_ link: DataLink) -> some View {
        Button {
            profileManager.openDataPage(link.page, forProfile: profileId)
        } label: {
            SettingsDetailRow(link.title, systemImage: link.systemImage) {
                Image(systemName: "arrow.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Password manager

    /// A well-known password-manager extension the pane can recognize in a
    /// profile and offer to install. Names are product brands — not localized.
    /// `installable: false` marks superseded store listings kept only so
    /// existing installs are still recognized.
    private struct PasswordManagerEntry: Identifiable {
        let id: String
        let name: String
        var installable: Bool = true
    }

    private static let knownPasswordManagers: [PasswordManagerEntry] = [
        PasswordManagerEntry(id: PhiExtensionID.icloudPasswords, name: "iCloud Passwords"),
        PasswordManagerEntry(id: PhiExtensionID.onePassword, name: "1Password"),
        PasswordManagerEntry(id: PhiExtensionID.bitwarden, name: "Bitwarden"),
        PasswordManagerEntry(id: PhiExtensionID.lastPass, name: "LastPass"),
        PasswordManagerEntry(id: PhiExtensionID.dashlane, name: "Dashlane"),
        PasswordManagerEntry(id: PhiExtensionID.protonPass, name: "Proton Pass"),
        PasswordManagerEntry(id: PhiExtensionID.nordPass, name: "NordPass"),
        PasswordManagerEntry(id: PhiExtensionID.nordPassLegacy, name: "NordPass", installable: false),
        PasswordManagerEntry(id: PhiExtensionID.keeper, name: "Keeper"),
        PasswordManagerEntry(id: PhiExtensionID.keePassXC, name: "KeePassXC-Browser"),
    ]

    /// Known password managers the profile has enabled, in catalog order.
    /// Multiple entries are expected — users do run more than one.
    private var detectedPasswordManagers: [PasswordManagerEntry] {
        let enabledIds = Set(profileExtensions.filter(\.enabled).map(\.id))
        return Self.knownPasswordManagers.filter { enabledIds.contains($0.id) }
    }

    /// What the install menu offers: current store listings not installed in
    /// any state (a disabled install would make a re-install a silent no-op)
    /// and not already mid-install.
    private var installablePasswordManagers: [PasswordManagerEntry] {
        let installedIds = Set(profileExtensions.map(\.id))
        return Self.knownPasswordManagers.filter {
            $0.installable && !installedIds.contains($0.id)
                && !installingManagerIds.contains($0.id)
        }
    }

    /// In-flight installs still shown with a spinner; an id drops out the
    /// moment the poll sees it enabled (it re-enters as a detected row).
    private var installingPasswordManagers: [PasswordManagerEntry] {
        let enabledIds = Set(profileExtensions.filter(\.enabled).map(\.id))
        return Self.knownPasswordManagers.filter {
            installingManagerIds.contains($0.id) && !enabledIds.contains($0.id)
        }
    }

    /// The Password Manager row's second line: the already-installed managers'
    /// icons (tooltip names each) plus a spinner per in-flight install,
    /// right-aligned under the install menu. Only shown when non-empty, so the
    /// row stays single-line until a manager is detected.
    private var installedPasswordManagersLine: some View {
        HStack(spacing: 8) {
            ForEach(detectedPasswordManagers) { manager in
                passwordManagerIcon(manager)
            }
            ForEach(installingPasswordManagers) { manager in
                ProgressView()
                    .controlSize(.small)
                    .help(String(format: NSLocalizedString("settings.profiles.passwordManager.installingTooltip", value: "Installing %@", comment: "Profiles settings - tooltip on the spinner of a password manager mid-install"),
                                 manager.name))
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.bottom, 12)
    }

    /// The manager's real extension icon, falling back to a key glyph when the
    /// icon hasn't arrived (or couldn't be read). Hover reveals the name.
    @ViewBuilder
    private func passwordManagerIcon(_ manager: PasswordManagerEntry) -> some View {
        Group {
            if let icon = profileExtensions.first(where: { $0.id == manager.id })?.icon {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "key.fill")
                    .font(.system(size: 14))
                    .themedForeground(.textSecondary)
            }
        }
        .frame(width: 20, height: 20)
        .help(manager.name)
    }

    private var installPasswordManagerMenu: some View {
        Menu {
            ForEach(installablePasswordManagers) { manager in
                Button(manager.name) {
                    installPasswordManager(manager)
                }
            }
        } label: {
            trailingControlPill {
                Text(NSLocalizedString("settings.profiles.passwordManager.installAction", value: "Install\u{2026}", comment: "Profiles settings - install password manager menu label"))
                    .font(.system(size: 13))
                    .themedForeground(.textPrimary)
                Spacer(minLength: 4)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .medium))
                    .themedForeground(.textSecondary)
            }
        }
        .pillMenuStyle()
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(installablePasswordManagers.isEmpty)
        .help(NSLocalizedString("settings.profiles.passwordManager.installTooltip", value: "Install a password manager", comment: "Profiles settings - tooltip on the install password manager menu"))
    }

    /// Triggers a silent Chrome Web Store install into the profile and starts
    /// polling for it to land. Install results only surface through a global
    /// delegate today, so the pane re-reads the profile's extension list
    /// rather than plumbing a new event path for one row's spinner.
    private func installPasswordManager(_ manager: PasswordManagerEntry) {
        installingManagerIds.insert(manager.id)
        profileManager.installExtensions([manager.id], forProfile: profileId)
        pollForPasswordManagerInstall(manager.id, profileId: profileId)
    }

    /// Re-reads the profile's extensions every couple of seconds until the
    /// just-installed manager is enabled, giving up quietly after ~30s — the
    /// row then folds back into the install menu. Guards on the still-active
    /// profile like `loadDetail`; a profile switch clears `installingManagerIds`,
    /// which also stops the poll.
    private func pollForPasswordManagerInstall(_ extensionId: String,
                                               profileId: String,
                                               attempt: Int = 0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            guard activeProfileId == profileId,
                  installingManagerIds.contains(extensionId) else { return }
            profileManager.extensions(forProfile: profileId) { extensions in
                guard activeProfileId == profileId,
                      installingManagerIds.contains(extensionId) else { return }
                profileExtensions = extensions
                let landed = extensions.contains { $0.id == extensionId && $0.enabled }
                if landed || attempt >= 14 {
                    installingManagerIds.remove(extensionId)
                } else {
                    pollForPasswordManagerInstall(extensionId,
                                                  profileId: profileId,
                                                  attempt: attempt + 1)
                }
            }
        }
    }

    // MARK: - Detail loading

    /// Loads the profile's search engines and download location and swaps the
    /// new values in place. The previously shown controls stay put until the
    /// new data arrives — no clear-and-spinner on switch — so changing
    /// profiles doesn't flash: the bridge always answers a runloop later, which
    /// used to make the wiped, mid-load state briefly visible. Only the first
    /// load, when there's nothing cached to keep, shows the loading placeholder.
    ///
    /// All round-trips guard on the still-active profile so a fast profile
    /// switch can't let a slow off-profile load clobber the newer selection.
    private func loadDetail(_ profileId: String) {
        // Keep whatever's on screen; only show the loading state when there's
        // nothing cached to keep (first load).
        isLoadingDetail = searchEngines.isEmpty
        profileManager.searchEngines(forProfile: profileId) { engines in
            guard activeProfileId == profileId else { return }
            searchEngines = engines
            defaultEngineId = engines.first(where: { $0.isDefault })?.id ?? engines.first?.id ?? ""
            isLoadingDetail = false
        }
        profileManager.downloadLocation(forProfile: profileId) { path in
            guard activeProfileId == profileId else { return }
            downloadPath = path ?? ""
        }
        profileManager.extensions(forProfile: profileId) { extensions in
            guard activeProfileId == profileId else { return }
            profileExtensions = extensions
        }
    }

    private var searchBinding: Binding<String> {
        Binding(
            get: { defaultEngineId },
            set: { newId in
                guard newId != defaultEngineId else { return }
                let previous = defaultEngineId
                let profileId = profileId
                defaultEngineId = newId
                profileManager.setDefaultSearchEngine(newId, forProfile: profileId) { success, _ in
                    if !success, activeProfileId == profileId { defaultEngineId = previous }
                }
            }
        )
    }

    private func chooseDownloadLocation() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = NSLocalizedString("settings.profiles.downloadLocation.chooseButton", value: "Choose", comment: "Profiles settings - download folder picker confirm button")
        panel.message = NSLocalizedString("settings.profiles.downloadLocation.pickerMessage", value: "Choose a download location for this profile.",
                                          comment: "Profiles settings - download folder picker message")
        if !downloadPath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: downloadPath, isDirectory: true)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let newPath = url.path
        let previous = downloadPath
        let profileId = profileId
        downloadPath = newPath
        profileManager.setDownloadLocation(newPath, forProfile: profileId) { success, _ in
            if !success, activeProfileId == profileId { downloadPath = previous }
        }
    }
}

private extension View {
    /// `ButtonMenuStyle` requires macOS 13; macOS 12 falls back to the
    /// borderless native popup look for these pill menus.
    @ViewBuilder
    func pillMenuStyle() -> some View {
        if #available(macOS 13.0, *) {
            self.menuStyle(.button)
        } else {
            self.menuStyle(.borderlessButton)
        }
    }
}

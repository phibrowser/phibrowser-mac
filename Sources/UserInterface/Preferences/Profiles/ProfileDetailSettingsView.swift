// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import SwiftUI
import AppKit

/// One profile's browser settings: search engine, download location, and
/// quick links into that profile's data & settings pages. The detail column
/// of the Profiles pane, and inlined by the General pane while only one
/// profile exists.
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
    @State private var saveForLaterOverridePath: String = ""
    @State private var isLoadingDetail: Bool = false

    private var profileManager: ProfileManager { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsDetailCard {
                SettingsDetailRow(NSLocalizedString("settings.profiles.details.searchEngineLabel", value: "Search Engine", comment: "Profiles settings - search engine row label"),
                                  systemImage: "magnifyingglass") {
                    searchEngineControl
                }
                SettingsRowDivider()
                SettingsDetailRow(NSLocalizedString("settings.profiles.details.downloadLocationLabel", value: "Download Location", comment: "Profiles settings - download location row label"),
                                  systemImage: "arrow.down.to.line") {
                    downloadLocationControl
                }
                if SaveForLaterService.featureEnabled {
                    SettingsRowDivider()
                    SettingsDetailRow(NSLocalizedString("settings.profiles.details.folioLabel", value: "Folio Folder", comment: "Profiles settings - per-profile Folio destination override row label"),
                                      systemImage: "bookmark") {
                        saveForLaterControl
                    }
                }
            }
            dataAndSettingsSection
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            activeProfileId = profileId
            loadDetail(profileId)
        }
        .onChange(of: profileId) { _, newProfileId in
            activeProfileId = newProfileId
            loadDetail(newProfileId)
        }
    }

    /// Uniform chrome for the detail card's trailing controls (search engine,
    /// download location): one fixed-width pill so the rows read as a single
    /// aligned control column. Content lays out leading-to-trailing inside the
    /// fixed width — put a Spacer before any trailing chevron.
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
            .menuStyle(.button)
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

    /// Per-profile Folio destination. Unlike the download location
    /// this is a client concept stored in `PhiPreferences`, so the reads and
    /// writes are synchronous; a profile without an override follows the
    /// General settings folder.
    @ViewBuilder
    private var saveForLaterControl: some View {
        HStack(spacing: 4) {
            Button {
                chooseSaveForLaterFolder()
            } label: {
                trailingControlPill {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 12))
                        .themedForeground(.textSecondary)
                    Text(saveForLaterFolderName)
                        .font(.system(size: 13))
                        .themedForeground(.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(.plain)
            if !saveForLaterOverridePath.isEmpty {
                Button {
                    PhiPreferences.SaveForLater.setFolderOverride(nil, forProfile: profileId)
                    saveForLaterOverridePath = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .themedForeground(.textSecondary)
                }
                .buttonStyle(.plain)
                .help(NSLocalizedString("settings.profiles.folio.clearOverrideHelp", value: "Follow the General settings folder", comment: "Profiles settings - help text on the control that removes this profile's Folio folder override"))
            }
        }
    }

    private var saveForLaterFolderName: String {
        guard !saveForLaterOverridePath.isEmpty else {
            return NSLocalizedString("settings.profiles.folio.sameAsGeneral", value: "Same as General", comment: "Profiles settings - Folio folder shown when the profile has no override and follows the General settings folder")
        }
        return (saveForLaterOverridePath as NSString).lastPathComponent
    }

    private func chooseSaveForLaterFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = NSLocalizedString("settings.profiles.folio.chooseButton", value: "Choose", comment: "Profiles settings - Folio folder picker confirm button")
        panel.message = NSLocalizedString("settings.profiles.folio.pickerMessage", value: "Choose where this profile's saved pages are stored.", comment: "Profiles settings - Folio folder picker message")
        let current = saveForLaterOverridePath.isEmpty
            ? PhiPreferences.SaveForLater.globalFolderPath
            : saveForLaterOverridePath
        panel.directoryURL = URL(fileURLWithPath: current, isDirectory: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        PhiPreferences.SaveForLater.setFolderOverride(url.path, forProfile: profileId)
        saveForLaterOverridePath = url.path
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
        saveForLaterOverridePath =
            PhiPreferences.SaveForLater.folderOverride(forProfile: profileId) ?? ""
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

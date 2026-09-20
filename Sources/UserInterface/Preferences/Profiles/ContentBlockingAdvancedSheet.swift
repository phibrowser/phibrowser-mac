// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import SwiftUI

/// The catalog sections of the Advanced Ad Block Settings sheet, in display
/// order. `regional` lists count as ads and follow the Block ads toggle.
enum ContentBlockingSection: String, CaseIterable, Identifiable {
    case ads, trackers, cookies, regional, custom, phi

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ads:
            return NSLocalizedString("settings.privacy.contentBlocking.advanced.section.ads", value: "Ad Blockers", comment: "Advanced ad block settings - Section title for ad filter lists")
        case .trackers:
            return NSLocalizedString("settings.privacy.contentBlocking.advanced.section.trackers", value: "Trackers", comment: "Advanced ad block settings - Section title for tracker filter lists")
        case .cookies:
            return NSLocalizedString("settings.privacy.contentBlocking.advanced.section.cookies", value: "Cookie Banners", comment: "Advanced ad block settings - Section title for cookie banner filter lists")
        case .regional:
            return NSLocalizedString("settings.privacy.contentBlocking.advanced.section.regional", value: "Regional", comment: "Advanced ad block settings - Section title for language-specific filter lists")
        case .custom:
            return NSLocalizedString("settings.privacy.contentBlocking.advanced.section.custom", value: "Custom", comment: "Advanced ad block settings - Section title for the user's own filter lists")
        case .phi:
            return NSLocalizedString("settings.privacy.contentBlocking.advanced.section.phi", value: "Phi", comment: "Advanced ad block settings - Section title for Phi's own filter lists")
        }
    }

    /// Whether the section's lists are active under the pane toggles.
    func isEnabled(in state: ContentBlockingState) -> Bool {
        switch self {
        case .ads, .regional: return state.blockAds
        case .trackers: return state.blockTrackers
        case .cookies: return state.blockCookieBanners
        case .custom, .phi: return state.blockAds || state.blockTrackers || state.blockCookieBanners
        }
    }
}

struct ContentBlockingSectionGroup: Identifiable {
    let section: ContentBlockingSection
    let lists: [ContentBlockingList]
    var id: String { section.id }
}

struct ContentBlockingAdvancedSheet: View {
    @ObservedObject var settings: ContentBlockingSettings
    @Environment(\.dismiss) private var dismiss

    /// Sections the sheet never shows. The Phi first-party list stays active
    /// in the engine (it follows whichever pane toggle is on) but is not
    /// user-selectable, so it is hidden rather than listed.
    static let hiddenSections: Set<ContentBlockingSection> = [.phi]

    /// Groups `lists` by section in display order, keeping catalog order
    /// inside each section; hidden sections and sections without lists are
    /// omitted, except Custom, which always shows so the user can add one.
    static func groups(from lists: [ContentBlockingList]) -> [ContentBlockingSectionGroup] {
        ContentBlockingSection.allCases.compactMap { section in
            if hiddenSections.contains(section) { return nil }
            let members = lists.filter { $0.category == section.rawValue }
            if members.isEmpty && section != .custom { return nil }
            return ContentBlockingSectionGroup(section: section, lists: members)
        }
    }

    @State private var showAddFilter = false
    @State private var waitingForDownloads = false

    /// Checked lists Done still has to download, across every section.
    static func missingIds(in state: ContentBlockingState) -> [String] {
        state.lists.filter { $0.checked && $0.category != "phi" && !$0.available && !$0.isDownloading }.map(\.id)
    }

    static func anyDownloading(in state: ContentBlockingState) -> Bool {
        state.lists.contains { $0.checked && $0.isDownloading }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text(NSLocalizedString("settings.privacy.contentBlocking.advanced.title", value: "Advanced Ad Block Settings", comment: "Advanced ad block settings - Sheet title"))
                    .font(.system(size: 15, weight: .semibold))
                    .themedForeground(.textPrimary)
                Spacer()
                Button(NSLocalizedString("settings.privacy.contentBlocking.advanced.updateDownloaded", value: "Update Downloaded", comment: "Advanced ad block settings - Button that downloads every already-downloaded filter list again to pick up new rules")) {
                    settings.refreshLists()
                }
                .controlSize(.small)
                .disabled(settings.state == nil)
                .help(NSLocalizedString("settings.privacy.contentBlocking.advanced.updateDownloaded.help", value: "Fetch the latest rules for every list already downloaded", comment: "Advanced ad block settings - Tooltip of the Update Downloaded button"))
            }
            Text(NSLocalizedString("settings.privacy.contentBlocking.advanced.intro", value: "Check the filter lists this profile uses; Done downloads any that are missing. A section only takes effect while its switch is on. Nothing is downloaded until you ask.", comment: "Advanced ad block settings - Introductory sentence under the sheet title"))
                .font(.system(size: 12))
                .themedForeground(.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 20) {
                    if let state = settings.state {
                        ForEach(Self.groups(from: state.lists)) { group in
                            sectionView(group)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button(downloading
                       ? NSLocalizedString("settings.privacy.contentBlocking.ruleSets.downloading", value: "Downloading…", comment: "Choose rule sets sheet - Done button label while the chosen lists are being downloaded")
                       : NSLocalizedString("settings.privacy.contentBlocking.advanced.done", value: "Done", comment: "Advanced ad block settings - Button that downloads the chosen lists still missing and closes the sheet")) {
                    done()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(downloading)
            }
        }
        .padding(24)
        .frame(width: 520, height: 560)
        .themedBackground(PhiPreferences.fixedWindowBackground)
        .sheet(isPresented: $showAddFilter) {
            ContentBlockingCustomFilterSheet(settings: settings)
        }
        .onChange(of: settings.state) { _, state in
            guard waitingForDownloads, let state, !Self.anyDownloading(in: state) else { return }
            waitingForDownloads = false
            if Self.missingIds(in: state).isEmpty {
                dismiss()
            }
        }
    }

    private var downloading: Bool {
        guard let state = settings.state else { return false }
        return Self.anyDownloading(in: state)
    }

    private func done() {
        guard let state = settings.state else {
            dismiss()
            return
        }
        let missing = Self.missingIds(in: state)
        if missing.isEmpty {
            dismiss()
            return
        }
        waitingForDownloads = true
        settings.downloadLists(missing)
    }

    private func sectionView(_ group: ContentBlockingSectionGroup) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(group.section.title)
                .font(.system(size: 12, weight: .semibold))
                .themedForeground(.textSecondary)
            SettingsDetailCard {
                ForEach(Array(group.lists.enumerated()), id: \.element.id) { index, list in
                    if index > 0 { Divider() }
                    ContentBlockingListRow(list: list,
                                           onToggle: { checked in settings.setList(list.id, checked: checked) },
                                           onDownload: { settings.downloadList(list.id) },
                                           onRemove: { settings.removeCustomList(list.id) })
                }
                if group.section == .custom {
                    if !group.lists.isEmpty { Divider() }
                    HStack {
                        Spacer()
                        Button(NSLocalizedString("settings.privacy.contentBlocking.advanced.addFilter", value: "Add Filter…", comment: "Advanced ad block settings - Button opening the sheet that adds a custom filter list")) {
                            showAddFilter = true
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
        }
    }
}

/// One list row: checkbox (use it), title, a download-state line when the
/// list is not on disk, one control (see `Control`) and the info button with
/// the details popover. Downloaded catalog lists are never deleted from
/// here: the files are shared by every profile, so removing one would
/// silently switch other profiles' blocking off; unchecking is enough.
struct ContentBlockingListRow: View {
    /// The single control at the end of a row, chosen from the list's state.
    enum Control: Equatable {
        /// Nothing to manage: bundled, or downloaded.
        case none
        /// Not on disk and not being fetched: offer to download it.
        case download
        /// A fetch is in progress.
        case downloading
        /// A custom list: offer to remove it entirely.
        case removeCustom
    }

    let list: ContentBlockingList
    let onToggle: (Bool) -> Void
    var onDownload: () -> Void = {}
    var onRemove: () -> Void = {}
    @State private var showInfo = false

    static func control(for list: ContentBlockingList) -> Control {
        if list.isDownloading { return .downloading }
        if list.isCustom { return .removeCustom }
        return list.available ? .none : .download
    }

    /// The line under a list that is downloading or has no text on disk;
    /// nil once it does.
    static func availabilityLine(for list: ContentBlockingList) -> String? {
        if list.isDownloading {
            return downloadingLine(for: list)
        }
        if list.available { return nil }
        if list.lastError.isEmpty {
            return NSLocalizedString("settings.privacy.contentBlocking.listInfo.notDownloaded", value: "Not downloaded yet", comment: "Advanced ad block settings - Details line for a filter list that has not been downloaded")
        }
        return String(format: NSLocalizedString("settings.privacy.contentBlocking.list.downloadFailed", value: "Not downloaded: %@", comment: "Advanced ad block settings - Line under a filter list whose download failed; %@ is the error"), list.lastError)
    }

    /// "Downloading…" with the bytes so far, and the total when the server
    /// announced one.
    static func downloadingLine(for list: ContentBlockingList) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let received = formatter.string(fromByteCount: list.downloadedBytes)
        if let total = list.totalBytes, total > 0 {
            return String(format: NSLocalizedString("settings.privacy.contentBlocking.list.downloadingOf", value: "Downloading… %@ of %@", comment: "Advanced ad block settings - Line under a filter list being downloaded; the two values are bytes received and the total size"), received, formatter.string(fromByteCount: total))
        }
        if list.downloadedBytes > 0 {
            return String(format: NSLocalizedString("settings.privacy.contentBlocking.list.downloadingBytes", value: "Downloading… %@", comment: "Advanced ad block settings - Line under a filter list being downloaded when the total size is unknown; the value is bytes received"), received)
        }
        return NSLocalizedString("settings.privacy.contentBlocking.list.downloading", value: "Downloading…", comment: "Advanced ad block settings - Line under a filter list whose download is in progress")
    }

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { list.checked }, set: onToggle))
                .labelsHidden()
                .toggleStyle(.checkbox)
            VStack(alignment: .leading, spacing: 2) {
                Text(list.title)
                    .font(.system(size: 13))
                    .themedForeground(.textPrimary)
                if let line = Self.availabilityLine(for: list) {
                    Text(line)
                        .font(.system(size: 11))
                        .themedForeground(.textTertiary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            switch Self.control(for: list) {
            case .none:
                EmptyView()
            case .download:
                Button(action: onDownload) {
                    Image(systemName: "arrow.down.circle")
                        .themedForeground(.textSecondary)
                }
                .buttonStyle(.plain)
                .help(NSLocalizedString("settings.privacy.contentBlocking.list.download", value: "Download this list", comment: "Advanced ad block settings - Tooltip of the button downloading a filter list"))
            case .downloading:
                if let total = list.totalBytes, total > 0 {
                    ProgressView(value: Double(list.downloadedBytes), total: Double(total))
                        .progressViewStyle(.linear)
                        .frame(width: 72)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            case .removeCustom:
                Button(action: onRemove) {
                    Image(systemName: "trash")
                        .themedForeground(.textSecondary)
                }
                .buttonStyle(.plain)
                .help(NSLocalizedString("settings.privacy.contentBlocking.list.remove", value: "Remove this filter", comment: "Advanced ad block settings - Tooltip of the button removing a custom filter list"))
            }
            Button {
                showInfo.toggle()
            } label: {
                Image(systemName: "info.circle")
                    .themedForeground(.textSecondary)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showInfo, arrowEdge: .trailing) {
                ContentBlockingListInfoPopover(list: list)
            }
        }
        .padding(.vertical, 8)
    }
}

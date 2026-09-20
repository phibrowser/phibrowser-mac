// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import SwiftUI

/// "Custom Filters": the profile's own filter lists (a URL or pasted
/// rules), which apply to every toggle. Done downloads any checked URL list
/// still missing and closes once it landed. Catalog lists are chosen per
/// toggle in `ContentBlockingRuleSetSheet`.
struct ContentBlockingCustomFiltersSheet: View {
    @ObservedObject var settings: ContentBlockingSettings
    @Environment(\.dismiss) private var dismiss
    @State private var showAddFilter = false
    @State private var waitingForDownloads = false

    /// Checked custom lists Done still has to download.
    static func missingIds(in state: ContentBlockingState) -> [String] {
        state.lists.filter { $0.isCustom && $0.checked && !$0.available && !$0.isDownloading }.map(\.id)
    }

    static func anyDownloading(in state: ContentBlockingState) -> Bool {
        state.lists.contains { $0.isCustom && $0.checked && $0.isDownloading }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(NSLocalizedString("settings.privacy.contentBlocking.custom.title", value: "Custom Filters", comment: "Custom filters sheet - Title"))
                .font(.system(size: 15, weight: .semibold))
                .themedForeground(.textPrimary)
            Text(NSLocalizedString("settings.privacy.contentBlocking.custom.intro", value: "Your own filter lists, from a URL or pasted rules. They apply whenever any of the three switches is on.", comment: "Custom filters sheet - Introductory sentence"))
                .font(.system(size: 12))
                .themedForeground(.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView(.vertical) {
                if let state = settings.state {
                    let custom = state.lists.filter(\.isCustom)
                    SettingsDetailCard {
                        ForEach(Array(custom.enumerated()), id: \.element.id) { index, list in
                            if index > 0 { Divider() }
                            ContentBlockingListRow(list: list,
                                                   onToggle: { checked in settings.setList(list.id, checked: checked) },
                                                   onDownload: { settings.downloadList(list.id) },
                                                   onRemove: { settings.removeCustomList(list.id) })
                        }
                        if custom.isEmpty {
                            Text(NSLocalizedString("settings.privacy.contentBlocking.custom.empty", value: "No custom filters yet.", comment: "Custom filters sheet - Placeholder when the profile has no custom list"))
                                .font(.system(size: 12))
                                .themedForeground(.textTertiary)
                                .padding(.vertical, 8)
                        } else {
                            Divider()
                        }
                        HStack {
                            Spacer()
                            Button(NSLocalizedString("settings.privacy.contentBlocking.advanced.addFilter", value: "Add Filter…", comment: "Custom filters sheet - Button opening the sheet that adds a custom filter list")) {
                                showAddFilter = true
                            }
                        }
                        .padding(.vertical, 8)
                    }
                }
            }
            HStack {
                Spacer()
                Button(downloading
                       ? NSLocalizedString("settings.privacy.contentBlocking.ruleSets.downloading", value: "Downloading…", comment: "Choose rule sets sheet - Done button label while the chosen lists are being downloaded")
                       : NSLocalizedString("settings.privacy.contentBlocking.advanced.done", value: "Done", comment: "Custom filters sheet - Button that downloads the chosen lists still missing and closes the sheet")) {
                    done()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(downloading)
            }
        }
        .padding(24)
        .frame(width: 480, height: 400)
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

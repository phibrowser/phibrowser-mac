// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import SwiftUI

/// Which lists a pane toggle uses, and whether any of them is on disk.
/// Downloads are explicit user actions, so turning a toggle on whose lists
/// are not downloaded yet opens `ContentBlockingRuleSetSheet`.
enum ContentBlockingRuleSets {
    /// The catalog lists a toggle controls: ads also covers regional lists,
    /// and every toggle can use the profile's custom lists.
    static func lists(for category: ContentBlockingCategory, in state: ContentBlockingState) -> [ContentBlockingList] {
        let sections: Set<String>
        switch category {
        case .ads: sections = ["ads", "regional"]
        case .trackers: sections = ["trackers"]
        case .cookieBanners: sections = ["cookies"]
        }
        return state.lists.filter { sections.contains($0.category) }
    }

    /// True when the toggle would have nothing to apply: none of its checked
    /// lists (or custom lists) has text on disk.
    static func needsDownload(for category: ContentBlockingCategory, in state: ContentBlockingState) -> Bool {
        let usable = lists(for: category, in: state) + state.lists.filter { $0.isCustom }
        return !usable.contains { $0.checked && $0.available }
    }

    /// Toggles that are on without a usable rule set (their last list was
    /// deleted or unchecked); the pane turns them off.
    static func togglesToTurnOff(in state: ContentBlockingState) -> [ContentBlockingCategory] {
        var off: [ContentBlockingCategory] = []
        if state.blockAds && needsDownload(for: .ads, in: state) { off.append(.ads) }
        if state.blockCookieBanners && needsDownload(for: .cookieBanners, in: state) { off.append(.cookieBanners) }
        if state.blockTrackers && needsDownload(for: .trackers, in: state) { off.append(.trackers) }
        return off
    }

    /// The line under a toggle: the checked lists, the custom lists (which
    /// apply to every toggle), and their state.
    static func summary(for category: ContentBlockingCategory, in state: ContentBlockingState) -> String {
        let checked = lists(for: category, in: state).filter(\.checked)
        let custom = state.lists.filter { $0.isCustom && $0.checked }
        if checked.isEmpty && custom.isEmpty {
            return NSLocalizedString("settings.privacy.contentBlocking.summary.noneSelected", value: "No rule sets selected", comment: "Profile settings - Line under a content blocking toggle when no filter list is checked for it")
        }
        // One list reads as its name; more become a count.
        var names: String
        switch checked.count {
        case 0: names = ""
        case 1: names = checked[0].title
        default: names = String(format: NSLocalizedString("settings.privacy.contentBlocking.summary.count", value: "%d rule sets", comment: "Profile settings - Line under a content blocking toggle when two or more filter lists are chosen for it; %d is the count"), checked.count)
        }
        if !custom.isEmpty {
            let customPart = custom.count == 1
                ? NSLocalizedString("settings.privacy.contentBlocking.summary.customOne", value: "1 custom list", comment: "Profile settings - Part of the line under a content blocking toggle when the user has one custom list, which applies to every toggle")
                : String(format: NSLocalizedString("settings.privacy.contentBlocking.summary.custom", value: "%d custom lists", comment: "Profile settings - Part of the line under a content blocking toggle counting the user's custom lists, which apply to every toggle; %d is the count"), custom.count)
            names = names.isEmpty ? customPart : names + " + " + customPart
        }
        if (checked + custom).contains(where: \.isDownloading) {
            return names + " · " + NSLocalizedString("settings.privacy.contentBlocking.list.downloading", value: "Downloading…", comment: "Advanced ad block settings - Line under a filter list whose download is in progress")
        }
        let missing = (checked + custom).filter { !$0.available }
        if !missing.isEmpty {
            return names + " · " + String(format: NSLocalizedString("settings.privacy.contentBlocking.summary.notDownloaded", value: "%d not downloaded", comment: "Profile settings - Suffix under a content blocking toggle; %d is how many of its checked lists are not downloaded"), missing.count)
        }
        return names
    }
}

/// "Choose rule sets": the toggle's catalog lists plus the profile's custom
/// lists (shared by all three toggles), each with a checkbox (use it) and a
/// download button (fetch its text). Choices apply as they are made. Done
/// downloads every checked list still missing and closes once they are all
/// on disk; a failed download keeps the sheet open with the error so Done
/// can retry. "Update Downloaded" refetches the lists shown here that are
/// on disk.
struct ContentBlockingRuleSetSheet: View {
    @ObservedObject var settings: ContentBlockingSettings
    let category: ContentBlockingCategory
    @Environment(\.dismiss) private var dismiss
    @State private var waitingForDownloads = false
    @State private var showAddFilter = false

    /// Every list this sheet shows.
    static func shownLists(for category: ContentBlockingCategory, in state: ContentBlockingState) -> [ContentBlockingList] {
        ContentBlockingRuleSets.lists(for: category, in: state) + state.lists.filter(\.isCustom)
    }

    /// Checked lists Done still has to download.
    static func missingIds(for category: ContentBlockingCategory, in state: ContentBlockingState) -> [String] {
        shownLists(for: category, in: state).filter { $0.checked && !$0.available && !$0.isDownloading }.map(\.id)
    }

    static func anyDownloading(for category: ContentBlockingCategory, in state: ContentBlockingState) -> Bool {
        shownLists(for: category, in: state).contains(where: \.isDownloading)
    }

    /// Lists shown here that are on disk and can be fetched again. Pasted
    /// custom lists have no source.
    static func downloadedIds(for category: ContentBlockingCategory, in state: ContentBlockingState) -> [String] {
        shownLists(for: category, in: state)
            .filter { $0.available && !$0.isDownloading && (!$0.isCustom || $0.sourceURL != nil) }
            .map(\.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .themedForeground(.textPrimary)
            Text(NSLocalizedString("settings.privacy.contentBlocking.ruleSets.intro", value: "Check the rule sets to use. Done downloads any that are missing from their publishers; nothing is downloaded until you ask. Custom lists apply to all three switches.", comment: "Choose rule sets sheet - Introductory sentence"))
                .font(.system(size: 12))
                .themedForeground(.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView(.vertical) {
                if let state = settings.state {
                    VStack(alignment: .leading, spacing: 16) {
                        SettingsDetailCard {
                            ForEach(Array(ContentBlockingRuleSets.lists(for: category, in: state).enumerated()), id: \.element.id) { index, list in
                                if index > 0 { Divider() }
                                ContentBlockingListRow(list: list,
                                                       onToggle: { checked in settings.setList(list.id, checked: checked) },
                                                       onDownload: { settings.downloadList(list.id) })
                            }
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text(NSLocalizedString("settings.privacy.contentBlocking.ruleSets.customSection", value: "Your custom lists (apply to every switch)", comment: "Choose rule sets sheet - Section title above the user's custom lists"))
                                .font(.system(size: 12, weight: .semibold))
                                .themedForeground(.textSecondary)
                            SettingsDetailCard {
                                let custom = state.lists.filter(\.isCustom)
                                ForEach(Array(custom.enumerated()), id: \.element.id) { index, list in
                                    if index > 0 { Divider() }
                                    ContentBlockingListRow(list: list,
                                                           onToggle: { checked in settings.setList(list.id, checked: checked) },
                                                           onDownload: { settings.downloadList(list.id) },
                                                           onRemove: { settings.removeCustomList(list.id) })
                                }
                                if !custom.isEmpty { Divider() }
                                HStack {
                                    Spacer()
                                    Button(NSLocalizedString("settings.privacy.contentBlocking.advanced.addFilter", value: "Add Filter…", comment: "Choose rule sets sheet - Button opening the sheet that adds a custom filter list")) {
                                        showAddFilter = true
                                    }
                                }
                                .padding(.vertical, 8)
                            }
                        }
                    }
                }
            }
            HStack {
                if let state = settings.state, !Self.downloadedIds(for: category, in: state).isEmpty {
                    Button(NSLocalizedString("settings.privacy.contentBlocking.ruleSets.update", value: "Update Downloaded", comment: "Choose rule sets sheet - Button at the bottom left that downloads the sheet's already-downloaded lists again to pick up new rules")) {
                        settings.downloadLists(Self.downloadedIds(for: category, in: state))
                    }
                    .disabled(downloading)
                    .help(NSLocalizedString("settings.privacy.contentBlocking.ruleSets.update.help", value: "Fetch the latest rules for the lists downloaded here", comment: "Choose rule sets sheet - Tooltip of the Update Downloaded button"))
                }
                Spacer()
                Button(downloading
                       ? NSLocalizedString("settings.privacy.contentBlocking.ruleSets.downloading", value: "Downloading…", comment: "Choose rule sets sheet - Done button label while the chosen lists are being downloaded")
                       : NSLocalizedString("settings.privacy.contentBlocking.ruleSets.done", value: "Done", comment: "Choose rule sets sheet - Button that downloads the chosen lists still missing and closes the sheet")) {
                    done()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(downloading)
            }
        }
        .padding(24)
        .frame(width: 480, height: 540)
        .themedBackground(PhiPreferences.fixedWindowBackground)
        .sheet(isPresented: $showAddFilter) {
            ContentBlockingCustomFilterSheet(settings: settings)
        }
        .onChange(of: settings.state) { _, state in
            // Close once the downloads Done started have all landed.
            guard waitingForDownloads, let state, !Self.anyDownloading(for: category, in: state) else { return }
            waitingForDownloads = false
            if Self.missingIds(for: category, in: state).isEmpty {
                dismiss()
            }
        }
    }

    private var downloading: Bool {
        guard let state = settings.state else { return false }
        return Self.anyDownloading(for: category, in: state)
    }

    private func done() {
        guard let state = settings.state else {
            dismiss()
            return
        }
        let missing = Self.missingIds(for: category, in: state)
        if missing.isEmpty {
            dismiss()
            return
        }
        waitingForDownloads = true
        settings.downloadLists(missing)
    }

    private var title: String {
        switch category {
        case .ads:
            return NSLocalizedString("settings.privacy.contentBlocking.ruleSets.title.ads", value: "Rule sets for blocking ads", comment: "Choose rule sets sheet - Title for the ads toggle")
        case .trackers:
            return NSLocalizedString("settings.privacy.contentBlocking.ruleSets.title.trackers", value: "Rule sets for blocking trackers", comment: "Choose rule sets sheet - Title for the trackers toggle")
        case .cookieBanners:
            return NSLocalizedString("settings.privacy.contentBlocking.ruleSets.title.cookies", value: "Rule sets for blocking cookie banners", comment: "Choose rule sets sheet - Title for the cookie banners toggle")
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

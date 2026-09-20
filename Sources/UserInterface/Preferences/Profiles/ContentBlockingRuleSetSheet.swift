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

    /// The action word after the summary; the line only shows while the
    /// toggle has something usable.
    static func actionLabel(for category: ContentBlockingCategory, in state: ContentBlockingState) -> String {
        NSLocalizedString("settings.privacy.contentBlocking.summary.change", value: "Change…", comment: "Profile settings - Action after the line under a content blocking toggle; opens the rule set chooser")
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
        // A count keeps the line short however many lists are chosen.
        var names = checked.isEmpty ? "" : String(format: NSLocalizedString("settings.privacy.contentBlocking.summary.count", value: "%d rule sets selected", comment: "Profile settings - Line under a content blocking toggle counting the filter lists chosen for it; %d is the count"), checked.count)
        if !custom.isEmpty {
            let customPart = String(format: NSLocalizedString("settings.privacy.contentBlocking.summary.custom", value: "%d custom", comment: "Profile settings - Part of the line under a content blocking toggle counting the user's custom lists, which apply to every toggle; %d is the count"), custom.count)
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

/// "Choose rule sets": the lists a toggle uses, each with a checkbox (use
/// it) and a download button (fetch its text). Choices apply as they are
/// made. Done downloads every checked list that is still missing and closes
/// once they are all on disk; a failed download keeps the sheet open with
/// the error so Done can retry.
struct ContentBlockingRuleSetSheet: View {
    @ObservedObject var settings: ContentBlockingSettings
    let category: ContentBlockingCategory
    @Environment(\.dismiss) private var dismiss
    @State private var showAddFilter = false
    @State private var waitingForDownloads = false

    /// The checked lists of this sheet (the toggle's and the custom ones).
    static func chosenLists(for category: ContentBlockingCategory, in state: ContentBlockingState) -> [ContentBlockingList] {
        (ContentBlockingRuleSets.lists(for: category, in: state) + state.lists.filter(\.isCustom)).filter(\.checked)
    }

    /// Checked lists Done still has to download.
    static func missingIds(for category: ContentBlockingCategory, in state: ContentBlockingState) -> [String] {
        chosenLists(for: category, in: state).filter { !$0.available && !$0.isDownloading }.map(\.id)
    }

    static func anyDownloading(for category: ContentBlockingCategory, in state: ContentBlockingState) -> Bool {
        chosenLists(for: category, in: state).contains(where: \.isDownloading)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .themedForeground(.textPrimary)
            Text(NSLocalizedString("settings.privacy.contentBlocking.ruleSets.intro", value: "Check the rule sets to use. Done downloads any that are missing from their publishers; nothing is downloaded until you ask.", comment: "Choose rule sets sheet - Introductory sentence"))
                .font(.system(size: 12))
                .themedForeground(.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView(.vertical) {
                if let state = settings.state {
                    VStack(alignment: .leading, spacing: 16) {
                        SettingsDetailCard {
                            ForEach(Array(ContentBlockingRuleSets.lists(for: category, in: state).enumerated()), id: \.element.id) { index, list in
                                if index > 0 { Divider() }
                                ContentBlockingListRow(list: list, enabled: true,
                                                       onToggle: { checked in settings.setList(list.id, checked: checked) },
                                                       onDownload: { settings.downloadList(list.id) },
                                                       onDeleteDownload: { settings.deleteListDownload(list.id) })
                            }
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text(NSLocalizedString("settings.privacy.contentBlocking.ruleSets.customSection", value: "Your custom lists (apply to every toggle)", comment: "Choose rule sets sheet - Section title above the user's custom lists"))
                                .font(.system(size: 12, weight: .semibold))
                                .themedForeground(.textSecondary)
                            SettingsDetailCard {
                                let custom = state.lists.filter(\.isCustom)
                                ForEach(Array(custom.enumerated()), id: \.element.id) { index, list in
                                    if index > 0 { Divider() }
                                    ContentBlockingListRow(list: list, enabled: true,
                                                           onToggle: { checked in settings.setList(list.id, checked: checked) },
                                                           onDownload: { settings.downloadList(list.id) },
                                                           onDeleteDownload: { settings.deleteListDownload(list.id) },
                                                           onRemove: { settings.removeCustomList(list.id) })
                                }
                                if !custom.isEmpty { Divider() }
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
            HStack {
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
        .frame(width: 480, height: 520)
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

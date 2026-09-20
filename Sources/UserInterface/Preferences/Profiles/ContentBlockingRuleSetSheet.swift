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

    /// The action word after the summary: "Choose…" while the toggle has
    /// nothing usable, "Change…" otherwise.
    static func actionLabel(for category: ContentBlockingCategory, in state: ContentBlockingState) -> String {
        needsDownload(for: category, in: state)
            ? NSLocalizedString("settings.privacy.contentBlocking.summary.choose", value: "Choose rule sets…", comment: "Profile settings - Action after the line under a content blocking toggle when it has no usable rule set; opens the rule set chooser")
            : NSLocalizedString("settings.privacy.contentBlocking.summary.change", value: "Change…", comment: "Profile settings - Action after the line under a content blocking toggle; opens the rule set chooser")
    }

    /// The line under a toggle: the checked lists, the custom lists (which
    /// apply to every toggle), and their state.
    static func summary(for category: ContentBlockingCategory, in state: ContentBlockingState) -> String {
        let checked = lists(for: category, in: state).filter(\.checked)
        let custom = state.lists.filter { $0.isCustom && $0.checked }
        if checked.isEmpty && custom.isEmpty {
            return NSLocalizedString("settings.privacy.contentBlocking.summary.noneSelected", value: "No rule sets selected", comment: "Profile settings - Line under a content blocking toggle when no filter list is checked for it")
        }
        var names = checked.map(\.title).joined(separator: ", ")
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

/// "Choose rule sets": the lists a toggle uses, each with a checkbox and its
/// download state, and a Download button for the checked ones that are
/// missing. Cancel turns the toggle back off when it was just switched on.
struct ContentBlockingRuleSetSheet: View {
    @ObservedObject var settings: ContentBlockingSettings
    let category: ContentBlockingCategory
    /// Set when the sheet opened because the toggle was just turned on.
    let revertsToggleOnCancel: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var showAddFilter = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .themedForeground(.textPrimary)
            Text(NSLocalizedString("settings.privacy.contentBlocking.ruleSets.intro", value: "Rule sets are downloaded from their publishers only when you ask. Choose which to use, then download the ones that are missing.", comment: "Choose rule sets sheet - Introductory sentence"))
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
                Button(NSLocalizedString("settings.privacy.contentBlocking.ruleSets.cancel", value: "Cancel", comment: "Choose rule sets sheet - Cancel button")) {
                    if revertsToggleOnCancel {
                        settings.setCategory(category, enabled: false)
                    }
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button(NSLocalizedString("settings.privacy.contentBlocking.ruleSets.download", value: "Download", comment: "Choose rule sets sheet - Button that downloads the checked lists that are missing")) {
                    settings.downloadLists(missingCheckedIds)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(missingCheckedIds.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 480, height: 520)
        .themedBackground(PhiPreferences.fixedWindowBackground)
        .sheet(isPresented: $showAddFilter) {
            ContentBlockingCustomFilterSheet(settings: settings)
        }
    }

    private var missingCheckedIds: [String] {
        guard let state = settings.state else { return [] }
        let candidates = ContentBlockingRuleSets.lists(for: category, in: state) + state.lists.filter(\.isCustom)
        return candidates.filter { $0.checked && !$0.available }.map(\.id)
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

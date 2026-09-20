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

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(NSLocalizedString("settings.privacy.contentBlocking.advanced.title", value: "Advanced Ad Block Settings", comment: "Advanced ad block settings - Sheet title"))
                .font(.system(size: 15, weight: .semibold))
                .themedForeground(.textPrimary)
            Text(NSLocalizedString("settings.privacy.contentBlocking.advanced.intro", value: "Choose the filter lists Phi applies. Lists in a section only take effect while that section's switch is on in Privacy settings.", comment: "Advanced ad block settings - Introductory sentence under the sheet title"))
                .font(.system(size: 12))
                .themedForeground(.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 20) {
                    if let state = settings.state {
                        ForEach(Self.groups(from: state.lists)) { group in
                            sectionView(group, enabled: group.section.isEnabled(in: state))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button(NSLocalizedString("settings.privacy.contentBlocking.advanced.done", value: "Done", comment: "Advanced ad block settings - Button closing the sheet")) {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520, height: 560)
        .themedBackground(PhiPreferences.fixedWindowBackground)
        .sheet(isPresented: $showAddFilter) {
            ContentBlockingCustomFilterSheet(settings: settings)
        }
    }

    private func sectionView(_ group: ContentBlockingSectionGroup, enabled: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(group.section.title)
                .font(.system(size: 12, weight: .semibold))
                .themedForeground(.textSecondary)
            SettingsDetailCard {
                ForEach(Array(group.lists.enumerated()), id: \.element.id) { index, list in
                    if index > 0 { Divider() }
                    ContentBlockingListRow(list: list, enabled: enabled,
                                           onToggle: { checked in settings.setList(list.id, checked: checked) },
                                           onRemove: list.isCustom ? { settings.removeCustomList(list.id) } : nil)
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

/// One list row: checkbox, title, a download-state line when the list is
/// not on disk, an info button with the details popover, and a remove
/// button for custom lists.
struct ContentBlockingListRow: View {
    let list: ContentBlockingList
    let enabled: Bool
    let onToggle: (Bool) -> Void
    var onRemove: (() -> Void)? = nil
    @State private var showInfo = false

    /// The line under a list that has no text on disk yet; nil once it does.
    static func availabilityLine(for list: ContentBlockingList) -> String? {
        if list.available { return nil }
        if list.lastError.isEmpty {
            return NSLocalizedString("settings.privacy.contentBlocking.list.downloading", value: "Downloading…", comment: "Advanced ad block settings - Line under a filter list whose first download is in progress")
        }
        return String(format: NSLocalizedString("settings.privacy.contentBlocking.list.downloadFailed", value: "Not downloaded: %@", comment: "Advanced ad block settings - Line under a filter list whose download failed; %@ is the error"), list.lastError)
    }

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { list.checked }, set: onToggle))
                .labelsHidden()
                .toggleStyle(.checkbox)
            VStack(alignment: .leading, spacing: 2) {
                Text(list.title)
                    .font(.system(size: 13))
                    .themedForeground(enabled ? .textPrimary : .textTertiary)
                if let line = Self.availabilityLine(for: list) {
                    Text(line)
                        .font(.system(size: 11))
                        .themedForeground(.textTertiary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let onRemove {
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
        .disabled(!enabled)
    }
}

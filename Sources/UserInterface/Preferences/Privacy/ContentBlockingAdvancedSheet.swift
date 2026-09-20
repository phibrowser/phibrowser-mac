// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import SwiftUI

/// The catalog sections of the Advanced Ad Block Settings sheet, in display
/// order. `regional` lists count as ads and follow the Block ads toggle.
enum ContentBlockingSection: String, CaseIterable, Identifiable {
    case ads, trackers, cookies, regional, phi

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
        case .phi: return state.blockAds || state.blockTrackers || state.blockCookieBanners
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

    /// Help page opened by "Learn more".
    static let learnMoreURL = URL(string: "https://phibrowser.com/help/content-blocking")!

    /// Sections the sheet never shows. The Phi first-party list stays active
    /// in the engine (it follows whichever pane toggle is on) but is not
    /// user-selectable, so it is hidden rather than listed.
    static let hiddenSections: Set<ContentBlockingSection> = [.phi]

    /// Groups `lists` by section in display order, keeping catalog order
    /// inside each section; hidden sections and sections without lists are
    /// omitted.
    static func groups(from lists: [ContentBlockingList]) -> [ContentBlockingSectionGroup] {
        ContentBlockingSection.allCases.compactMap { section in
            if hiddenSections.contains(section) { return nil }
            let members = lists.filter { $0.category == section.rawValue }
            return members.isEmpty ? nil : ContentBlockingSectionGroup(section: section, lists: members)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(NSLocalizedString("settings.privacy.contentBlocking.advanced.title", value: "Advanced Ad Block Settings", comment: "Advanced ad block settings - Sheet title"))
                .font(.system(size: 15, weight: .semibold))
                .themedForeground(.textPrimary)
            HStack(spacing: 4) {
                Text(NSLocalizedString("settings.privacy.contentBlocking.advanced.intro", value: "Block common components found across the web by using additional rules and filters.", comment: "Advanced ad block settings - Introductory sentence under the sheet title"))
                    .font(.system(size: 12))
                    .themedForeground(.textSecondary)
                Link(NSLocalizedString("settings.privacy.contentBlocking.advanced.learnMore", value: "Learn more", comment: "Advanced ad block settings - Link to the help page about content blocking"),
                     destination: Self.learnMoreURL)
                    .font(.system(size: 12))
            }
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
    }

    private func sectionView(_ group: ContentBlockingSectionGroup, enabled: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(group.section.title)
                .font(.system(size: 12, weight: .semibold))
                .themedForeground(.textSecondary)
            SettingsDetailCard {
                ForEach(Array(group.lists.enumerated()), id: \.element.id) { index, list in
                    if index > 0 { Divider() }
                    ContentBlockingListRow(list: list, enabled: enabled) { checked in
                        settings.setList(list.id, checked: checked)
                    }
                }
            }
        }
    }
}

/// One list row: checkbox, title, and an info button with the details popover.
struct ContentBlockingListRow: View {
    let list: ContentBlockingList
    let enabled: Bool
    let onToggle: (Bool) -> Void
    @State private var showInfo = false

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { list.checked }, set: onToggle))
                .labelsHidden()
                .toggleStyle(.checkbox)
            Text(list.title)
                .font(.system(size: 13))
                .themedForeground(enabled ? .textPrimary : .textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
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

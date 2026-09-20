// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Combine
import SwiftUI

/// Holds the content blocking facade of the profile the section shows and
/// swaps it when the selection changes. Views observe this object so a
/// facade swap and the facade's own updates both redraw the section.
final class ContentBlockingSectionModel: ObservableObject {
    @Published private(set) var settings: ContentBlockingSettings?

    private let makeSettings: (String) -> ContentBlockingSettings
    private var cancellable: AnyCancellable?

    init(makeSettings: @escaping (String) -> ContentBlockingSettings = { ContentBlockingSettings(profileId: $0) }) {
        self.makeSettings = makeSettings
    }

    func select(_ profileId: String) {
        guard settings?.profileId != profileId else { return }
        let facade = makeSettings(profileId)
        settings = facade
        // Forward the facade's changes so views observing the model refresh.
        cancellable = facade.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        facade.refresh()
    }
}

/// The "Content blocking" part of a profile's detail settings: the three
/// toggles, the Advanced Settings sheet and the status small print. Content
/// blocking is per profile, so it lives with the other per-profile settings
/// rather than in a pane of its own.
struct ContentBlockingSettingsSection: View {
    let profileId: String

    @StateObject private var model = ContentBlockingSectionModel()
    @State private var showAdvanced = false
    /// The toggle whose rule sets the chooser sheet shows, and whether the
    /// toggle should turn on when the sheet closes with a usable rule set
    /// (the user just tried to switch it on).
    @State private var ruleSetChooser: RuleSetChooser?

    struct RuleSetChooser: Identifiable {
        let category: ContentBlockingCategory
        let enablesOnClose: Bool
        var id: String { "\(category)" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(NSLocalizedString("settings.privacy.contentBlocking.title", value: "Content blocking", comment: "Profile settings - Section title above the ad, cookie banner and tracker toggles"))
                .font(.system(size: 12))
                .themedForeground(.textSecondary)
                .padding(.leading, 2)
            SettingsDetailCard {
                toggleRow(
                    title: NSLocalizedString("settings.privacy.contentBlocking.blockAds", value: "Block ads", comment: "Profile settings - Toggle title for blocking ads"),
                    symbol: "hand.raised.fill", category: .ads,
                    value: model.settings?.state?.blockAds)
                SettingsRowDivider()
                toggleRow(
                    title: NSLocalizedString("settings.privacy.contentBlocking.blockCookieBanners", value: "Block cookie banners", comment: "Profile settings - Toggle title for hiding cookie consent banners"),
                    symbol: "circle.grid.2x2.fill", category: .cookieBanners,
                    value: model.settings?.state?.blockCookieBanners)
                SettingsRowDivider()
                toggleRow(
                    title: NSLocalizedString("settings.privacy.contentBlocking.blockTrackers", value: "Block trackers", comment: "Profile settings - Toggle title for blocking trackers"),
                    symbol: "eyeglasses", category: .trackers,
                    value: model.settings?.state?.blockTrackers)
                SettingsRowDivider()
                HStack {
                    Spacer()
                    Button(NSLocalizedString("settings.privacy.contentBlocking.advancedButton", value: "Advanced Settings", comment: "Profile settings - Button opening the Advanced Ad Block Settings sheet")) {
                        showAdvanced = true
                    }
                    .disabled(model.settings?.state == nil)
                }
                .padding(.vertical, 8)
            }
            ForEach(Self.diagnosticsLines(for: model.settings?.state), id: \.self) { line in
                Text(line)
                    .font(.system(size: 11))
                    .themedForeground(.textTertiary)
                    .padding(.horizontal, 4)
            }
        }
        .onAppear { model.select(profileId) }
        .onChange(of: profileId) { _, newProfileId in model.select(newProfileId) }
        .sheet(isPresented: $showAdvanced) {
            if let settings = model.settings {
                ContentBlockingAdvancedSheet(settings: settings)
            }
        }
        .sheet(item: $ruleSetChooser, onDismiss: chooserClosed) { chooser in
            if let settings = model.settings {
                ContentBlockingRuleSetSheet(settings: settings, category: chooser.category)
            }
        }
        .onChange(of: ruleSetChooser?.id) { _, _ in
            if let ruleSetChooser { lastChooser = ruleSetChooser }
        }
        .onChange(of: model.settings?.state) { _, state in
            // A toggle is only on while it has something to apply.
            guard let settings = model.settings, let state else { return }
            for category in ContentBlockingRuleSets.togglesToTurnOff(in: state) {
                settings.setCategory(category, enabled: false)
            }
        }
    }

    /// A toggle turns on only with a usable rule set: otherwise the chooser
    /// opens first and the toggle follows what the user picked there.
    private func setCategory(_ category: ContentBlockingCategory, enabled: Bool) {
        guard let settings = model.settings else { return }
        if enabled, let state = settings.state,
           ContentBlockingRuleSets.needsDownload(for: category, in: state) {
            ruleSetChooser = RuleSetChooser(category: category, enablesOnClose: true)
            return
        }
        settings.setCategory(category, enabled: enabled)
    }

    private func chooserClosed() {
        guard let chooser = lastChooser, chooser.enablesOnClose,
              let settings = model.settings, let state = settings.state,
              !ContentBlockingRuleSets.needsDownload(for: chooser.category, in: state) else { return }
        settings.setCategory(chooser.category, enabled: true)
    }

    /// The chooser that was open last; `sheet(item:)` clears the item before
    /// `onDismiss` runs.
    @State private var lastChooser: RuleSetChooser?

    /// The small print under the card: the rule build failed and the previous
    /// rules stay in use, or a toggle is on with nothing downloaded (then the
    /// last download error, if any). Nothing is shown for the normal states,
    /// and the session's blocked count stays in the state for diagnosis only
    /// (owner decisions, 2026-09-20).
    static func diagnosticsLines(for state: ContentBlockingState?) -> [String] {
        guard let state else { return [] }
        switch state.status {
        case .degraded:
            var lines = [NSLocalizedString("settings.privacy.contentBlocking.status.degraded", value: "Filtering is running with the last good rules", comment: "Profile settings - Status line shown when the latest rule build failed and the previous rules stay in use")]
            if !state.statusDetail.isEmpty {
                lines.append(state.statusDetail)
            }
            return lines
        case .noLists:
            return [NSLocalizedString("settings.privacy.contentBlocking.status.noLists", value: "Nothing is blocked until a rule set is downloaded.", comment: "Profile settings - Status line shown when a toggle is on but none of its filter lists has been downloaded")]
        case .active, .building, .disabled:
            return []
        }
    }

    private func toggleRow(title: String,
                           symbol: String,
                           category: ContentBlockingCategory,
                           value: Bool?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsDetailRow(title, systemImage: symbol) {
                Toggle("", isOn: Binding(
                    get: { value ?? false },
                    set: { newValue in setCategory(category, enabled: newValue) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .themedTint(.themeColor)
                    .disabled(value == nil)
            }
            if value == true, let state = model.settings?.state,
               !ContentBlockingRuleSets.needsDownload(for: category, in: state) {
                Button {
                    ruleSetChooser = RuleSetChooser(category: category, enablesOnClose: false)
                } label: {
                    HStack(spacing: 4) {
                        Text(ContentBlockingRuleSets.summary(for: category, in: state))
                            .themedForeground(.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text(ContentBlockingRuleSets.actionLabel(for: category, in: state))
                            .foregroundStyle(Color.accentColor)
                            .fixedSize()
                    }
                    .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .padding(.leading, 34)
                .padding(.bottom, 8)
                .help(NSLocalizedString("settings.privacy.contentBlocking.summary.help", value: "Choose and download rule sets", comment: "Profile settings - Tooltip of the line under a content blocking toggle that opens the rule set chooser"))
            }
        }
    }
}

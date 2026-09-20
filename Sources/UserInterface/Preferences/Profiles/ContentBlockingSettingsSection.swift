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
    }

    /// The small print under the card: the status and its detail when
    /// something is off. The session's blocked count stays in the state for
    /// diagnosis but is not shown (owner decision, 2026-09-20).
    static func diagnosticsLines(for state: ContentBlockingState?) -> [String] {
        guard let state else { return [] }
        var lines: [String] = []
        switch state.status {
        case .degraded:
            lines.append(NSLocalizedString("settings.privacy.contentBlocking.status.degraded", value: "Filtering is running with the last good rules", comment: "Profile settings - Status line shown when the latest rule build failed and the previous rules stay in use"))
            if !state.statusDetail.isEmpty {
                lines.append(state.statusDetail)
            }
        case .disabled:
            lines.append(NSLocalizedString("settings.privacy.contentBlocking.status.disabled", value: "Content blocking is off", comment: "Profile settings - Status line shown when every content blocking toggle is off"))
        case .active, .building:
            break
        }
        return lines
    }

    private func toggleRow(title: String,
                           symbol: String,
                           category: ContentBlockingCategory,
                           value: Bool?) -> some View {
        SettingsDetailRow(title, systemImage: symbol) {
            Toggle("", isOn: Binding(
                get: { value ?? false },
                set: { newValue in model.settings?.setCategory(category, enabled: newValue) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .themedTint(.themeColor)
                .disabled(value == nil)
        }
    }
}

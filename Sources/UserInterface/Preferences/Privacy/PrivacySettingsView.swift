// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import SwiftUI

struct PrivacySettingsView: View {
    @ObservedObject private var profileManager = ProfileManager.shared
    @ObservedObject private var spaceManager = SpaceManager.shared
    @StateObject private var model = PrivacySettingsModel()
    @State private var showAdvanced = false

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 24) {
                if profileManager.userAssignableProfiles.count > 1 {
                    profilePicker
                }
                contentBlockingCard
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 36)
            .padding(.horizontal, 36)
        }
        .themedBackground(PhiPreferences.fixedWindowBackground)
        .frame(width: 680, height: 561)
        .onAppear {
            profileManager.refresh()
            model.reconcile(profiles: profileManager.userAssignableProfiles,
                            activeProfileId: spaceManager.activeSpace?.profileId)
        }
        .onChange(of: profileManager.profiles.map(\.profileId)) { _ in
            model.reconcile(profiles: profileManager.userAssignableProfiles,
                            activeProfileId: spaceManager.activeSpace?.profileId)
        }
        .sheet(isPresented: $showAdvanced) {
            if let settings = model.settings {
                ContentBlockingAdvancedSheet(settings: settings)
            }
        }
    }

    // MARK: - Profile picker

    private var profilePicker: some View {
        SettingsDetailCard {
            SettingsDetailRow(NSLocalizedString("settings.privacy.profilePicker.label", value: "Settings for profile", comment: "Privacy settings - Label of the picker choosing which profile the privacy settings apply to")) {
                // Before the model has reconciled, fall back to the first
                // profile so the Picker never holds a selection without a tag.
                Picker("", selection: Binding(
                    get: {
                        model.selectedProfileId
                            ?? profileManager.userAssignableProfiles.first?.profileId ?? ""
                    },
                    set: { model.select($0.isEmpty ? nil : $0) })) {
                    ForEach(profileManager.userAssignableProfiles) { profile in
                        Text(profile.displayName).tag(profile.profileId)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 220)
            }
        }
    }

    // MARK: - Content blocking

    private var contentBlockingCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(NSLocalizedString("settings.privacy.contentBlocking.title", value: "Content blocking", comment: "Privacy settings - Section title above the ad, cookie banner and tracker toggles"))
                .font(.system(size: 13, weight: .semibold))
                .themedForeground(.textPrimary)
            SettingsDetailCard {
                toggleRow(
                    title: NSLocalizedString("settings.privacy.contentBlocking.blockAds", value: "Block ads", comment: "Privacy settings - Toggle title for blocking ads"),
                    symbol: "hand.raised.fill", tint: .red, category: .ads,
                    value: model.settings?.state?.blockAds)
                Divider()
                toggleRow(
                    title: NSLocalizedString("settings.privacy.contentBlocking.blockCookieBanners", value: "Block cookie banners", comment: "Privacy settings - Toggle title for hiding cookie consent banners"),
                    symbol: "circle.grid.2x2.fill", tint: .orange, category: .cookieBanners,
                    value: model.settings?.state?.blockCookieBanners)
                Divider()
                toggleRow(
                    title: NSLocalizedString("settings.privacy.contentBlocking.blockTrackers", value: "Block trackers", comment: "Privacy settings - Toggle title for blocking trackers"),
                    symbol: "eyeglasses", tint: .yellow, category: .trackers,
                    value: model.settings?.state?.blockTrackers)
                Divider()
                HStack {
                    Spacer()
                    Button(NSLocalizedString("settings.privacy.contentBlocking.advancedButton", value: "Advanced Settings", comment: "Privacy settings - Button opening the Advanced Ad Block Settings sheet")) {
                        showAdvanced = true
                    }
                    .disabled(model.settings?.state == nil)
                }
                .padding(.vertical, 12)
            }
            if let statusLine {
                Text(statusLine)
                    .font(.system(size: 11))
                    .themedForeground(.textTertiary)
                    .padding(.horizontal, 4)
            }
        }
    }

    private var statusLine: String? {
        guard let state = model.settings?.state else { return nil }
        switch state.status {
        case .degraded:
            return NSLocalizedString("settings.privacy.contentBlocking.status.degraded", value: "Filtering is running with the last good rules", comment: "Privacy settings - Status line shown when the latest rule build failed and the previous rules stay in use")
        case .disabled:
            return NSLocalizedString("settings.privacy.contentBlocking.status.disabled", value: "Content blocking is off", comment: "Privacy settings - Status line shown when every content blocking toggle is off")
        case .active, .building:
            return nil
        }
    }

    private func toggleRow(title: String,
                           symbol: String,
                           tint: Color,
                           category: ContentBlockingCategory,
                           value: Bool?) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(tint)
                .frame(width: 24, alignment: .center)
            Text(title)
                .font(.system(size: 13))
                .themedForeground(.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Toggle("", isOn: Binding(
                get: { value ?? false },
                set: { newValue in model.settings?.setCategory(category, enabled: newValue) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .themedTint(.themeColor)
                .disabled(value == nil)
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

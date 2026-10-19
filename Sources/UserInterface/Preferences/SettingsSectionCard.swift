// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import SwiftUI
import AppKit

extension View {
    /// The card chrome shared by the settings panes: the themed item
    /// background, 7pt continuous corners, and a themed hairline border —
    /// matching the General/Shortcuts panes (`GeneralContainerView`).
    func settingsCardChrome() -> some View {
        self
            .themedBackground(.settingItemBackground)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .themedStroke(.border)
            }
    }
}

/// A bordered, themed content well used by the master-detail settings panes
/// (Profiles, Spaces) to group `SettingsDetailRow`s. Mirrors the General pane's
/// container styling.
struct SettingsDetailCard<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .padding(.horizontal, 12)
        .settingsCardChrome()
    }
}

/// A labelled row inside a `SettingsDetailCard`: a label on the left and a
/// trailing control (picker, button, …) on the right. Mirrors the General
/// pane's `GeneralRowView` styling. The card owns the fixed 12pt horizontal
/// insets; the control keeps its preferred width and the label receives all
/// remaining space, with 12pt between adjacent row elements.
struct SettingsDetailRow<Control: View>: View {
    private let label: String
    private let systemImage: String?
    private let control: Control

    init(_ label: String, systemImage: String? = nil, @ViewBuilder control: () -> Control) {
        self.label = label
        self.systemImage = systemImage
        self.control = control()
    }

    var body: some View {
        HStack(spacing: 12) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .regular))
                    .themedForeground(.textSecondary)
                    .frame(width: 24, alignment: .center)
            }
            Text(label)
                .font(.system(size: 13))
                .themedForeground(.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            control
                .layoutPriority(1)
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Hairline separator between rows inside a settings card (the system divider,
/// matching the General pane).
struct SettingsRowDivider: View {
    var body: some View {
        Divider()
    }
}

/// Small "Default" pill marking the default Space or Profile in the
/// master-detail settings lists, so the system default — which can't be deleted
/// or moved to another profile — is identifiable at a glance.
struct SettingsDefaultBadge: View {
    /// White-on-accent variant for rows highlighted with the solid system
    /// accent (the focused Space row), where the default gray pill vanishes.
    var onAccent: Bool = false

    var body: some View {
        SettingsBadge(text: NSLocalizedString("settings.defaultBadge", value: "Default", comment: "Settings - badge marking the default Space or Profile"),
                      onAccent: onAccent)
    }
}

/// The small capsule pill behind `SettingsDefaultBadge`, for other short labels
/// in the same style (the sync setup's "Recommended").
struct SettingsBadge: View {
    let text: String
    var onAccent: Bool = false

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .themedForeground(onAccent ? ThemedColor(.white) : .textSecondary)
            // Never wrap or compress: under tight row width (e.g. the Spaces list
            // row, where the profile picker takes space) the badge must keep its
            // pill on one line and let the name truncate instead.
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                onAccent ? Color.white.opacity(0.2) : Color.secondary.opacity(0.15),
                in: Capsule()
            )
    }
}

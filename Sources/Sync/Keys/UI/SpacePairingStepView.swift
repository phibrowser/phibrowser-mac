// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import SwiftUI

/// Step-2 two-column table (§6.4), structured as paired row halves to align columns. Own no State:
/// PairingWizardViewModel retains selections for footer enablement, Back and error/Retry (§5.2).
struct SpacePairingStepView: View {
    @ObservedObject var viewModel: PairingWizardViewModel
    let model: SpacePairingModel

    /// Localized unresolved-name display; pure logic returns nil.
    static let unresolvedName = NSLocalizedString(
        "—", comment: "Pairing wizard - a name that can’t be resolved (an unmapped profile, or an empty Space name on the confirmation page)")

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(NSLocalizedString("Match your Spaces", comment: "Pairing wizard - step 2 title"))
                .font(.title2.bold())
                .themedForeground(.textPrimaryStrong)
            Text(NSLocalizedString(
                "Pick the account Space each Space on this Mac belongs to, or add it to your account as a new Space. Spaces in your account that aren’t on this Mac are added here automatically. Nothing on this Mac is deleted.",
                comment: "Pairing wizard - step 2 explanation"))
                .font(.body)
                .themedForeground(.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 16) {
                Text(NSLocalizedString("This Mac", comment: "Pairing wizard - local column header"))
                    .font(.headline)
                    .themedForeground(.textPrimaryStrong)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(NSLocalizedString("Account", comment: "Pairing wizard - account column header"))
                    .font(.headline)
                    .themedForeground(.textPrimaryStrong)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            VStack(spacing: 0) {
                ForEach(Array(model.rows.enumerated()), id: \.element.spaceId) { index, local in
                    if index > 0 { SettingsRowDivider() }
                    row(local)
                }
                if let defaultRow = model.defaultRow {
                    if !model.rows.isEmpty { SettingsRowDivider() }
                    defaultSpaceRow(defaultRow)
                }
            }
            .padding(.horizontal, 12)
            .settingsCardChrome()

            if !model.unassignedAccountSpaces.isEmpty {
                Text(NSLocalizedString(
                    "sync.pairing.spacesToAdd",
                    value: "Spaces to add from your account",
                    comment: "Space pairing - heading for account Spaces that will be created on this Mac"))
                    .font(.headline)
                    .themedForeground(.textPrimaryStrong)
                Text(NSLocalizedString(
                    "sync.pairing.spacesToAddExplanation",
                    value: "These Spaces will be added automatically when you finish pairing.",
                    comment: "Space pairing - explanation for account Spaces not matched to a local Space"))
                    .font(.body)
                    .themedForeground(.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(spacing: 0) {
                    ForEach(Array(model.unassignedAccountSpaces.enumerated()), id: \.element.syncUuid) { index, summary in
                        if index > 0 { SettingsRowDivider() }
                        accountSpaceToAdd(summary)
                    }
                }
                .padding(.horizontal, 12)
                .settingsCardChrome()
            }
        }
    }

    private func accountSpaceToAdd(_ summary: PhiAccountSpaceSummary) -> some View {
        HStack(spacing: 8) {
            SpaceIconView(storedValue: summary.iconName, size: 16,
                          symbolWeight: .regular, tint: Color.primary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.name).font(.body).themedForeground(.textPrimary)
                Text(model.profileName(for: summary) ?? Self.unresolvedName)
                    .font(.caption).themedForeground(.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }

    private func row(_ local: PhiLocalSpace) -> some View {
        HStack(alignment: .top, spacing: 16) {
            localCell(local)
            accountCell(local)
        }
        .padding(.vertical, 10)
    }

    private func localCell(_ local: PhiLocalSpace) -> some View {
        let profile = model.profileName(for: local) ?? Self.unresolvedName
        return HStack(spacing: 8) {
            SpaceIconView(storedValue: local.iconName, size: 16,
                          symbolWeight: .regular, tint: Color.primary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(local.name).font(.body).themedForeground(.textPrimary)
                Text(profile).font(.caption).themedForeground(.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(
            format: NSLocalizedString("Space “%1$@” on this Mac, in profile %2$@",
                                      comment: "Pairing wizard - accessibility label for a local Space row"),
            local.name, profile))
    }

    private func accountCell(_ local: PhiLocalSpace) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Picker("", selection: binding(for: local)) {
                    Text(NSLocalizedString("Choose…", comment: "Profiles settings - download location not set"))
                        .tag(SpacePairingModel.Assignment?.none)
                    ForEach(model.assignableAccountSpaces(for: local), id: \.syncUuid) { summary in
                        Label {
                            Text(String(
                                format: NSLocalizedString("%1$@ (%2$@)",
                                                          comment: "Pairing wizard - an account Space named %1$@ in profile %2$@"),
                                summary.name, model.profileName(for: summary) ?? Self.unresolvedName))
                        } icon: {
                            // Reuse the left column's icon component: icons quickly show that a local Space
                            // corresponds to the account Space.
                            SpaceIconView(storedValue: summary.iconName, size: 14,
                                          symbolWeight: .regular, tint: Color.primary)
                        }
                        .tag(SpacePairingModel.Assignment?.some(.existing(syncUuid: summary.syncUuid)))
                    }
                    Text(NSLocalizedString("Add as new",
                                           comment: "Pairing wizard - add this Space to the account as a new one"))
                        .tag(SpacePairingModel.Assignment?.some(.addAsNew))
                }
                .labelsHidden()
                .accessibilityLabel(String(
                    format: NSLocalizedString("Account Space for “%@”",
                                              comment: "Pairing wizard - accessibility label for the assignment picker"),
                    local.name))
                if model.assignment(for: local) != nil {
                    Image(systemName: "checkmark.circle.fill")
                        .themedForeground(.textSecondary)
                        .accessibilityHidden(true)   // Already conveyed by the Picker value.
                }
            }
            if model.assignment(for: local) == nil {
                Text(NSLocalizedString("Not assigned yet",
                                       comment: "Pairing wizard - account column placeholder for an undecided row"))
                    .font(.caption)
                    .themedForeground(.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Default Space is read-only with fixed account text: no picker, no allRowsDecided contribution or
    /// decision. It explains D1's constant identity.
    private func defaultSpaceRow(_ local: PhiLocalSpace) -> some View {
        HStack(alignment: .top, spacing: 16) {
            HStack(spacing: 8) {
                SpaceIconView(storedValue: local.iconName, size: 16,
                              symbolWeight: .regular, tint: Color.primary)
                    .accessibilityHidden(true)
                Text(local.name).font(.body).themedForeground(.textPrimary)
                SettingsDefaultBadge()
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(NSLocalizedString("Already in your account",
                                   comment: "Pairing wizard - default Space row, account side"))
                .font(.body)
                .themedForeground(.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(
            format: NSLocalizedString("Space “%@” is the default Space and is already in your account",
                                      comment: "Pairing wizard - accessibility label for the default Space row"),
            local.name))
    }

    /// Read via model.assignment(for:) so stale selections display Choose… rather than a blank Picker, as with
    /// ProfilePairingView.remoteChoiceBinding.
    private func binding(for local: PhiLocalSpace) -> Binding<SpacePairingModel.Assignment?> {
        Binding(get: { model.assignment(for: local) },
                set: { viewModel.assign($0, to: local.spaceId) })
    }
}

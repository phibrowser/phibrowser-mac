// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import SwiftUI

/// The confirmation page of "use your account's data" (docs/sync.md, "Sync method and replacing this Mac's
/// data"): what leaves this Mac, what the account brings, and a keep-or-delete choice for each local Profile
/// the account has no Profile for. The wizard footer owns Replace and Back.
struct ReplaceLocalConfirmView: View {
    let review: ReplaceLocalReview
    @Binding var decisions: [String: ExtraProfileDecision]
    /// A replace that already started: the Profile choices are fixed.
    let locked: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(NSLocalizedString("sync.pairing.replaceLocal.title",
                                   value: "Replace what’s on this Mac?",
                                   comment: "Sync setup - title of the page confirming that this Mac's data is replaced with the account's"))
                .font(.title2.bold())
                .themedForeground(.textPrimaryStrong)
            Text(NSLocalizedString("sync.pairing.replaceLocal.explanation",
                                   value: "Phi deletes this Mac’s Spaces, bookmarks, pinned tabs, URL rules and synced settings, then downloads your account’s. This can’t be undone. Your other devices aren’t affected.",
                                   comment: "Sync setup - explanation on the page confirming that this Mac's data is replaced with the account's"))
                .font(.body)
                .themedForeground(.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            kindCard(header: NSLocalizedString("sync.pairing.replaceLocal.removedHeader",
                                               value: "Removed from this Mac",
                                               comment: "Sync setup replace confirmation - header of the card listing the data deleted from this Mac"),
                     counts: review.removed, kinds: [.spaces, .bookmarks, .pinnedTabs, .urlRules],
                     spacesCaption: NSLocalizedString("sync.pairing.replaceLocal.spacesCloseTabs",
                                                      value: "Open tabs in them will close",
                                                      comment: "Sync setup replace confirmation - caption under the number of Spaces deleted from this Mac"))
            kindCard(header: NSLocalizedString("sync.pairing.replaceLocal.downloadedHeader",
                                               value: "Downloaded from your account",
                                               comment: "Sync setup replace confirmation - header of the card listing the data downloaded from the account"),
                     counts: review.downloaded, kinds: PairingDataSummary.Kind.allCases, spacesCaption: nil)
            if !review.extraLocals.isEmpty { profilesCard }
            if review.defaultUnavailable {
                Text(NSLocalizedString("sync.pairing.replaceLocal.defaultUnavailable",
                                       value: "Your account’s default profile can’t be read on this Mac, so this Mac’s data can’t be replaced right now. Choose Merge to match profiles yourself, or choose Finish later and try again.",
                                       comment: "Sync setup replace confirmation - shown instead of allowing the replacement when the account's default profile cannot be read on this Mac"))
                    .font(.callout)
                    .themedForeground(.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            secondaryLine(NSLocalizedString("sync.pairing.replaceLocal.untouched",
                                            value: "Tabs, history, passwords and extensions in profiles you keep stay as they are.",
                                            comment: "Sync setup replace confirmation - note on what the replacement does not change"))
            secondaryLine(NSLocalizedString("sync.pairing.replaceLocal.backupHint",
                                            value: "Want a copy first? Choose Finish later, then use Help › Manage User Data › Export User Data…",
                                            comment: "Sync setup replace confirmation - hint on exporting this Mac's data before replacing it; names the Finish later button and the Help menu path"))
        }
    }

    private func secondaryLine(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .themedForeground(.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Data cards

    /// A header and one row per kind: counted kinds above zero, uncounted kinds by name, then synced settings.
    private func kindCard(header: String, counts: PairingDataSummary.Counts,
                          kinds: [PairingDataSummary.Kind], spacesCaption: String?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            cardHeader(header)
            ForEach(counts.listedKinds(kinds), id: \.self) { kind in
                SettingsRowDivider()
                kindRow(PairingDataSummary.phrase(kind, count: counts.count(of: kind)),
                        caption: kind == .spaces ? spacesCaption : nil)
            }
            SettingsRowDivider()
            kindRow(PairingDataSummary.syncedSettings, caption: nil)
        }
        .padding(.horizontal, 12)
        .settingsCardChrome()
    }

    private func cardHeader(_ text: String) -> some View {
        Text(text)
            .font(.headline)
            .themedForeground(.textPrimaryStrong)
            .padding(.vertical, 10)
            .accessibilityAddTraits(.isHeader)
    }

    private func kindRow(_ text: String, caption: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(text).font(.body).themedForeground(.textPrimary)
            if let caption {
                Text(caption).font(.caption).themedForeground(.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Profiles card

    private var profilesCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            cardHeader(NSLocalizedString("sync.pairing.replaceLocal.profilesHeader",
                                         value: "Profiles on this Mac",
                                         comment: "Sync setup replace confirmation - header of the card listing this Mac's profiles"))
            SettingsRowDivider()
            defaultProfileRow
            ForEach(review.extraLocals) { local in
                SettingsRowDivider()
                extraProfileRow(local)
            }
            SettingsRowDivider()
            Text(NSLocalizedString("sync.pairing.replaceLocal.profileDeleteNote",
                                   value: "Deleting a profile also removes its passwords, history and extensions on this Mac.",
                                   comment: "Sync setup replace confirmation - caption under the profiles card explaining what deleting a profile removes"))
                .font(.caption)
                .themedForeground(.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 8)
        }
        .padding(.horizontal, 12)
        .settingsCardChrome()
    }

    private var defaultProfileRow: some View {
        HStack(spacing: 16) {
            Text(review.defaultProfileName).font(.body.bold()).themedForeground(.textPrimaryStrong)
            SettingsDefaultBadge()
            Spacer(minLength: 0)
            Text(review.defaultRegistersAsAccountDefault
                 ? NSLocalizedString("sync.pairing.replaceLocal.profileRegisteredDefault",
                                     value: "Registered as your account’s default profile",
                                     comment: "Sync setup replace confirmation - shown beside this Mac's default profile when the account has no default profile to match, so this one becomes the account's default")
                 : NSLocalizedString("sync.pairing.replaceLocal.profileMatchedDefault",
                                     value: "Matched with your account’s default profile",
                                     comment: "Sync setup replace confirmation - shown beside this Mac's default profile, which always pairs with the account's default profile"))
                .font(.body)
                .themedForeground(.textSecondary)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }

    private func extraProfileRow(_ local: PairingLocal) -> some View {
        HStack(spacing: 16) {
            Text(local.displayName).font(.body.bold()).themedForeground(.textPrimaryStrong)
            Spacer(minLength: 0)
            Picker("", selection: binding(for: local.profileId)) {
                Text(NSLocalizedString("sync.pairing.replaceLocal.profileKeep",
                                       value: "Keep and add to your account",
                                       comment: "Sync setup replace confirmation - option that keeps a profile on this Mac and adds it to the account"))
                    .tag(ExtraProfileDecision.keepAndRegister)
                Text(NSLocalizedString("sync.pairing.replaceLocal.profileDelete",
                                       value: "Delete from this Mac",
                                       comment: "Sync setup replace confirmation - option that deletes a profile and its data from this Mac"))
                    .tag(ExtraProfileDecision.deleteLocal)
            }
            .labelsHidden()
            .frame(maxWidth: 220)
            .disabled(locked)
            .accessibilityLabel(local.displayName)
        }
        .padding(.vertical, 12)
    }

    private func binding(for profileId: String) -> Binding<ExtraProfileDecision> {
        Binding(get: { decisions[profileId] ?? .keepAndRegister },
                set: { decisions[profileId] = $0 })
    }
}

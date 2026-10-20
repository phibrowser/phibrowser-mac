// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import SwiftUI

/// The confirmation page of "use your account's data" (docs/sync.md, "Sync method and replacing this Mac's
/// data"): what leaves this Mac, including the local Profiles the account has no Profile for, and what the
/// account brings. The wizard footer owns Replace and Back.
struct ReplaceLocalConfirmView: View {
    let review: ReplaceLocalReview

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(NSLocalizedString("sync.pairing.replaceLocal.title",
                                   value: "Replace what’s on this Mac?",
                                   comment: "Sync setup - title of the page confirming that this Mac's data is replaced with the account's"))
                .font(.title2.bold())
                .themedForeground(.textPrimaryStrong)
            Text(NSLocalizedString("sync.pairing.replaceLocal.explanation",
                                   value: "Phi deletes this Mac’s Spaces, bookmarks, pinned tabs, URL rules, synced settings and the Profiles your account doesn’t have, then downloads your account’s. This can’t be undone. Your other devices aren’t affected.",
                                   comment: "Sync setup - explanation on the page confirming that this Mac's data is replaced with the account's"))
                .font(.body)
                .themedForeground(.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            kindCard(header: NSLocalizedString("sync.pairing.replaceLocal.removedHeader",
                                               value: "Removed from this Mac",
                                               comment: "Sync setup replace confirmation - header of the card listing the data deleted from this Mac"),
                     counts: review.removed, kinds: [.spaces, .bookmarks, .pinnedTabs, .urlRules],
                     deletedProfiles: review.extraLocals,
                     spacesCaption: NSLocalizedString("sync.pairing.replaceLocal.spacesCloseTabs",
                                                      value: "Open tabs in them will close",
                                                      comment: "Sync setup replace confirmation - caption under the number of Spaces deleted from this Mac"))
            kindCard(header: NSLocalizedString("sync.pairing.replaceLocal.downloadedHeader",
                                               value: "Downloaded from your account",
                                               comment: "Sync setup replace confirmation - header of the card listing the data downloaded from the account"),
                     counts: review.downloaded, kinds: PairingDataSummary.Kind.allCases, spacesCaption: nil)
            if review.defaultUnavailable {
                Text(NSLocalizedString("sync.pairing.replaceLocal.defaultUnavailable",
                                       value: "Your account’s default profile can’t be read on this Mac, so this Mac’s data can’t be replaced right now. Choose Merge to match profiles yourself, or choose Finish later and try again.",
                                       comment: "Sync setup replace confirmation - shown instead of allowing the replacement when the account's default profile cannot be read on this Mac"))
                    .font(.callout)
                    .themedForeground(.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            secondaryLine(NSLocalizedString("sync.pairing.replaceLocal.untouched",
                                            value: "Profiles that match one in your account stay as they are, with their tabs, history, extensions and site data.",
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

    /// A header, then one row per kind: counted kinds above zero, uncounted kinds by name, then synced
    /// settings, then the deleted local Profiles by name (when any), matching the explanation's order.
    private func kindCard(header: String, counts: PairingDataSummary.Counts,
                          kinds: [PairingDataSummary.Kind], deletedProfiles: [PairingLocal] = [],
                          spacesCaption: String?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            cardHeader(header)
            ForEach(counts.listedKinds(kinds), id: \.self) { kind in
                SettingsRowDivider()
                kindRow(PairingDataSummary.phrase(kind, count: counts.count(of: kind)),
                        caption: kind == .spaces ? spacesCaption : nil)
            }
            SettingsRowDivider()
            kindRow(PairingDataSummary.syncedSettings, caption: nil)
            if !deletedProfiles.isEmpty {
                SettingsRowDivider()
                kindRow(Self.deletedProfilesText(deletedProfiles),
                        caption: Self.deletedProfilesCaption(count: deletedProfiles.count))
            }
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

    // MARK: - Deleted Profiles

    /// "1 profile: Scratch" or "2 profiles: Scratch, Work2", names in the review's order.
    static func deletedProfilesText(_ profiles: [PairingLocal]) -> String {
        let names = profiles.map(\.displayName).joined(separator: ", ")
        if profiles.count == 1 {
            return String(format: NSLocalizedString("sync.pairing.replaceLocal.removedProfile",
                                                    value: "1 profile: %@",
                                                    comment: "Sync setup replace confirmation - row naming the one profile deleted from this Mac because the account has no profile for it; %@ is the profile's name"),
                          names)
        }
        return String(format: NSLocalizedString("sync.pairing.replaceLocal.removedProfiles",
                                                value: "%1$d profiles: %2$@",
                                                comment: "Sync setup replace confirmation - row naming the profiles deleted from this Mac because the account has no profile for them; %1$d is their number (2 or more), %2$@ their names separated by commas"),
                      profiles.count, names)
    }

    static func deletedProfilesCaption(count: Int) -> String {
        count == 1
            ? NSLocalizedString("sync.pairing.replaceLocal.removedProfileData",
                                value: "Its history, extensions and site data on this Mac are deleted too.",
                                comment: "Sync setup replace confirmation - caption under the row naming the one profile deleted from this Mac")
            : NSLocalizedString("sync.pairing.replaceLocal.removedProfilesData",
                                value: "Their history, extensions and site data on this Mac are deleted too.",
                                comment: "Sync setup replace confirmation - caption under the row naming the profiles deleted from this Mac")
    }
}

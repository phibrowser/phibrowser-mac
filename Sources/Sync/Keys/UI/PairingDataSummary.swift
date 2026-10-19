// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

/// What each side holds, for the sync method step's comparison strip (docs/sync.md, "Sync method and
/// replacing this Mac's data"). This Mac's bookmark, pinned tab and URL rule counts come from the local
/// reset's inventory, so they match exactly what "use your account's data" removes. The account side's come
/// from the Space preview; a kind it could not count is listed by name only.
struct PairingDataSummary: Equatable {
    /// One side's counts. A nil count means the kind cannot be counted on that side.
    struct Counts: Equatable {
        var profiles: Int
        var spaces: Int
        var bookmarks: Int?
        var pinnedTabs: Int?
        var urlRules: Int?
    }

    enum Kind: CaseIterable {
        case profiles, spaces, bookmarks, pinnedTabs, urlRules
    }

    var local: Counts
    var account: Counts

    /// One line of the comparison strip: the side's label, then every kind, joined with " · ".
    static func stripLine(label: String, counts: Counts) -> String {
        Kind.allCases.map { phrase($0, count: counts.count(of: $0)) }
            .reduce(label) { String(format: joinFormat, $0, $1) }
    }

    /// "4 Spaces", or the kind's name when it cannot be counted ("Bookmarks").
    static func phrase(_ kind: Kind, count: Int?) -> String {
        guard let count else { return name(of: kind) }
        return String.localizedStringWithFormat(countFormat(kind), count)
    }

    static let syncedSettings = NSLocalizedString("sync.pairing.kind.syncedSettings",
        value: "Synced settings",
        comment: "Sync setup - row naming the synced browser settings that are replaced or downloaded when this Mac uses the account's data")

    private static let joinFormat = NSLocalizedString("sync.pairing.method.compare.join",
        value: "%1$@ · %2$@",
        comment: "Sync setup method step - joins two parts of a comparison line, such as \"This Mac\" and \"2 profiles\"; %1$@ is the text so far, %2$@ the next part")

    private static func countFormat(_ kind: Kind) -> String {
        switch kind {
        case .profiles:
            return NSLocalizedString("sync.pairing.count.profiles", value: "%lld profiles",
                comment: "Sync setup - number of browser profiles on this Mac or in the account; %lld is the number")
        case .spaces:
            return NSLocalizedString("sync.pairing.count.spaces", value: "%lld Spaces",
                comment: "Sync setup - number of Spaces on this Mac or in the account; %lld is the number")
        case .bookmarks:
            return NSLocalizedString("sync.pairing.count.bookmarks", value: "%lld bookmarks",
                comment: "Sync setup - number of bookmarks on this Mac or in the account; %lld is the number")
        case .pinnedTabs:
            return NSLocalizedString("sync.pairing.count.pinnedTabs", value: "%lld pinned tabs",
                comment: "Sync setup - number of pinned tabs on this Mac or in the account; %lld is the number")
        case .urlRules:
            return NSLocalizedString("sync.pairing.count.urlRules", value: "%lld URL rules",
                comment: "Sync setup - number of URL rules on this Mac or in the account; %lld is the number")
        }
    }

    /// Names for kinds the account side cannot count. Profiles and Spaces are always counted.
    private static func name(of kind: Kind) -> String {
        switch kind {
        case .profiles, .spaces:
            assertionFailure("Profiles and Spaces are always counted")
            return ""
        case .bookmarks:
            return NSLocalizedString("sync.pairing.kind.bookmarks", value: "Bookmarks",
                comment: "Sync setup - names bookmarks when their number in the account is not known")
        case .pinnedTabs:
            return NSLocalizedString("sync.pairing.kind.pinnedTabs", value: "Pinned tabs",
                comment: "Sync setup - names pinned tabs when their number in the account is not known")
        case .urlRules:
            return NSLocalizedString("sync.pairing.kind.urlRules", value: "URL rules",
                comment: "Sync setup - names URL rules when their number in the account is not known")
        }
    }
}

extension PairingDataSummary.Counts {
    func count(of kind: PairingDataSummary.Kind) -> Int? {
        switch kind {
        case .profiles: return profiles
        case .spaces: return spaces
        case .bookmarks: return bookmarks
        case .pinnedTabs: return pinnedTabs
        case .urlRules: return urlRules
        }
    }

    /// The kinds a confirmation card lists: counted kinds above zero, and uncounted kinds by name.
    func listedKinds(_ kinds: [PairingDataSummary.Kind] = PairingDataSummary.Kind.allCases)
    -> [PairingDataSummary.Kind] {
        kinds.filter { count(of: $0).map { $0 > 0 } ?? true }
    }
}

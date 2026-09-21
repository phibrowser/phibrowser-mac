// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

/// Pure step-2 decision model (§5.4), analogous to ProfilePairingModel without SwiftUI, strings or singletons.
///
/// 1. selections keyed by localSpaceId permits at most one decision per local Space.
/// 2. assignableAccountSpaces excludes UUIDs claimed by earlier rows; duplicate choices resolve in favor of
/// the first row, leaving later rows undecided. This structurally prevents user-created duplicate claims;
/// SpaceSyncMappingManager.syncUuidAlreadyClaimed is a second guard.
/// 3. assignment(for:) treats stale/unavailable existing UUIDs as undecided, preventing allRowsDecided from
/// counting blank rows.
struct SpacePairingModel {
    struct Input: Equatable {
        /// Pairable local Spaces from pairableSpaces (§3.4 final paragraph), excluding incognito and both
        /// agent characteristics but not requiring a mapped Profile. Includes default Space. currentSpaces is
        /// wrong here: step-1 Profile decisions are not applied until Finish, so that filter would hide their
        /// Spaces while the wizard is open.
        let locals: [PhiLocalSpace]
        /// Previewed account Spaces, excluding default Space, whose constant identity D1 handles and which is
        /// never selectable.
        let accountSpaces: [PhiAccountSpaceSummary]
        /// Local profileId → display name.
        let localProfileNames: [String: String]
        /// Account Profile UUID → display name, resolved in the VM by §5.2's three-level rule.
        let accountProfileNames: [String: String]
    }

    enum Assignment: Hashable {
        case existing(syncUuid: String)
        case addAsNew
    }

    let input: Input
    /// localSpaceId -> Assignment
    let selections: [String: Assignment]

    /// Decision rows are non-default local Spaces.
    var rows: [PhiLocalSpace] {
        input.locals.filter { $0.spaceId != LocalStore.defaultSpaceId }
    }

    /// Default Space is read-only: no picker, no allRowsDecided contribution and no decision. The row explains
    /// its constant identity (D1).
    var defaultRow: PhiLocalSpace? {
        input.locals.first { $0.spaceId == LocalStore.defaultSpaceId }
    }

    func assignment(for local: PhiLocalSpace) -> Assignment? {
        guard let stored = selections[local.spaceId] else { return nil }
        if case .existing(let uuid) = stored,
           !assignableAccountSpaces(for: local).contains(where: { $0.syncUuid == uuid }) {
            return nil
        }
        return stored
    }

    /// Retain a row's own selected UUID in its options so Picker can display it, unless an earlier row claimed
    /// it. Earlier rows win duplicates and later rows become undecided; otherwise both could retain the same
    /// account Space and leave mapping validation as the only guard.
    ///
    /// Iterate only non-default rows: stale default-Space selections claim nothing. Tie-breaks depend on
    /// input.locals order, which must stay stable across redraws.
    func assignableAccountSpaces(for local: PhiLocalSpace) -> [PhiAccountSpaceSummary] {
        let own: String? = {
            if case .existing(let uuid) = selections[local.spaceId] { return uuid }
            return nil
        }()
        var claimedByOthers: Set<String> = []
        var claimedByEarlierRows: Set<String> = []
        var seenSelf = false
        for row in rows {
            if row.spaceId == local.spaceId { seenSelf = true; continue }
            guard case .existing(let uuid) = selections[row.spaceId] else { continue }
            claimedByOthers.insert(uuid)
            if !seenSelf { claimedByEarlierRows.insert(uuid) }
        }
        return input.accountSpaces.filter { summary in
            guard !claimedByEarlierRows.contains(summary.syncUuid) else { return false }
            return summary.syncUuid == own || !claimedByOthers.contains(summary.syncUuid)
        }
    }

    /// Account Spaces unclaimed by any valid decision automatically land as new local rows/mappings at first
    /// drain after gate opening (R-D6-7), as step-2 copy explains. Derive claims from decisions(), not raw
    /// selections: stale UUIDs, losing duplicates and default-row stale choices claim nothing.
    var unassignedAccountSpaces: [PhiAccountSpaceSummary] {
        let claimed = Set(decisions().compactMap { decision -> String? in
            if case .existing(let uuid) = decision.assignment { return uuid }
            return nil
        })
        return input.accountSpaces.filter { !claimed.contains($0.syncUuid) }
    }

    var allRowsDecided: Bool {
        rows.allSatisfy { assignment(for: $0) != nil }
    }

    /// Set only undecided rows to addAsNew. Preserve existing decisions; this is a shortcut, not reset.
    func addAllAsNew() -> [String: Assignment] {
        var out = selections
        for row in rows where assignment(for: row) == nil {
            out[row.spaceId] = .addAsNew
        }
        return out
    }

    func decisions() -> [(localSpaceId: String, assignment: Assignment)] {
        rows.compactMap { row in
            guard let assignment = assignment(for: row) else { return nil }
            return (localSpaceId: row.spaceId, assignment: assignment)
        }
    }

    /// Owning Profile display name, or nil when unresolved. The view localizes the em dash; missing names
    /// never affect eligibility or selection.
    func profileName(for local: PhiLocalSpace) -> String? {
        input.localProfileNames[local.profileId]
    }

    func profileName(for summary: PhiAccountSpaceSummary) -> String? {
        input.accountProfileNames[summary.profileUuid]
    }
}

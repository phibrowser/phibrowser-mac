// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

/// The engine's view of local Profiles for the Profile entity (docs/sync.md, "Profile entity").
/// Main-actor, like `PhiSpaceLocalAccess`; the engine hops here for every call. Production
/// wiring is `AccountPhiSpaceAccess` (its conformance sits beside the class in
/// PhiSpaceLocalAccess.swift), which already owns the controller and Profile reads.
@MainActor
protocol PhiProfileLocalAccess: AnyObject {
    /// Mapped user Profiles only: `ProfileManager.userAssignableProfiles` (which already leaves out
    /// the Phi Chat and agent fallback Profiles) with an account uuid. Local-only Profiles are
    /// never published.
    func currentProfiles() -> [PhiLocalProfile]

    /// localProfileId -> account profile uuid, every persisted mapping, including those whose
    /// local Profile no longer exists.
    func allProfileMappings() -> [String: String]

    /// Whether `ProfileManager` has read a complete Profile list. Until then an absent local
    /// Profile proves nothing.
    func isProfileListEnumerated() -> Bool

    /// Renames a local Profile to an account name. Local names must be unique, so a taken name
    /// falls back to the auto-create suffix rule. Returns the resulting local name, or nil when
    /// the rename did not happen.
    func applyRemoteName(profileId: String, name: String) async -> String?

    /// Drops a mapping whose local Profile no longer exists, so auto-create sees the account
    /// uuid as missing again.
    func dropMapping(forProfileId profileId: String)

    /// Whether this device still has that user Profile (`userAssignableProfiles`).
    func isKnownLocalProfile(_ profileId: String) -> Bool

    /// The Profile ids a fresh bridge read lists, without republishing the cached list; nil when
    /// the read failed.
    func freshProfileIds() -> Set<String>?

    // MARK: Deletion (docs/sync.md, "Profile deletion and rename")

    /// The deletion journal: account profile uuid -> local profile id.
    func profileDeletionIntents() -> [String: String]
    /// Removes a journal entry once its tombstone committed or no tombstone is owed.
    func finishLocalProfileDeletion(syncUuid: String)
    /// Whether the Chromium deletion for this uuid is in flight right now.
    func isProfileBeingDeletedLocally(syncUuid: String) -> Bool
    /// Removes the local rows a deleted Profile leaves behind. Idempotent.
    func removeLocalRows(ofDeletedProfile localProfileId: String) async

    /// What on this device stands in the way of applying a remote Profile tombstone.
    func profileDeletionBlockers(localProfileId: String) -> ProfileDeletionBlockers
    /// Deletes the local Profile for a remote tombstone, the same way a local deletion does
    /// (chats archived, memories removed, key withdrawn, local rows removed), with no journal.
    /// True once Chromium has committed the deletion.
    func deleteForRemoteTombstone(localProfileId: String) async -> Bool
}

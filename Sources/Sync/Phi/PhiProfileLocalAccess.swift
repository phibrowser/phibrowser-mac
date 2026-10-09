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
}

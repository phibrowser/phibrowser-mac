// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

/// What the pairing reset would remove from this Mac, for the setup pages. Every count matches what
/// `clear(_:)` deletes, so a fresh install (the default Space, the Default Profile and empty bookmark
/// roots) is empty. Soft-deleted rule rows are deleted too but never shown; the reset verifies them
/// through `PhiDataCounts`.
struct LocalPhiInventory: Equatable {
    /// User Spaces other than `default-space`, sorted. Agent and Incognito Spaces are never listed.
    var nonDefaultSpaceIds: [String] = []
    var bookmarks = 0
    /// Folders other than the canonical per-Space roots.
    var bookmarkFolders = 0
    /// Pinned-tab rows in every scope, dormant copies included.
    var pinnedTabs = 0
    /// Live URL rules.
    var urlRules = 0
    /// The requested Profiles that still exist and will be deleted, sorted.
    var profileIdsToDelete: [String] = []

    var isEmpty: Bool {
        nonDefaultSpaceIds.isEmpty && bookmarks == 0 && bookmarkFolders == 0 && pinnedTabs == 0
            && urlRules == 0 && profileIdsToDelete.isEmpty
    }
}

struct LocalResetRequest: Equatable {
    /// Local Profiles the user chose to delete. Every other Profile is kept.
    var deleteProfileIds: Set<String> = []
}

/// The part of the reset the pairing wizard uses: what would be removed, and the removal itself.
/// `PhiLocalDataReset` is the production conformer; the wizard reaches it through a host seam
/// (`AppModalPairingHost`), so wizard tests substitute a recording fake.
@MainActor
protocol LocalPhiResetting: AnyObject {
    func inventory(deleting profileIds: Set<String>) throws -> LocalPhiInventory
    func clear(_ request: LocalResetRequest) async throws
}

/// Why the reset refused or stopped. Every precondition fails closed with its own case; nothing is
/// cleaned silently when the reset cannot prove it is safe.
enum PhiLocalDataResetError: Error, Equatable {
    /// P1: the device is paired, so a deletion could be published as a tombstone.
    case paired
    /// P1: retired or locked controller, another account, or a pending reconfiguration.
    case sessionUnavailable
    /// P2: sync history exists (or cannot be proven absent), so a deletion could reach the account.
    case syncHistoryPresent(PhiLocalDataReset.SyncHistory)
    /// P3.
    case importInProgress
    /// P3: an agent task runs in a Space or Profile the reset would delete.
    case agentTaskRunning
    /// P4: the Default Profile, or a Profile that is not user-assignable (the agent fallback).
    case profileNotDeletable(String)
    /// P4: a mapped Profile belongs to the account and is deleted only through sync.
    case profileMapped(String)
    /// The store counts or the Profile list could not be read; nothing is assumed empty.
    case inventoryUnavailable
    case roleNotPersisted
    case defaultSpaceUnavailable
    case defaultSpaceRebindRefused(SpaceManager.PairingResetRebind)
    case spaceDeletionRefused(spaceId: String, outcome: SpaceManager.PairingResetSpaceDeletion)
    /// A window is still bound to a Profile about to be deleted.
    case liveWindowsOnDeletedProfile(String)
    /// A Space row still binds a Profile about to be deleted.
    case profileInUse(String)
    case profileDeletionFailed(String, reason: String?)
    case profileRowCleanupFailed(String)
    case postconditionFailed(String)
}

/// Empties this Mac's Phi data so that pairing lands the account's data without merging
/// (docs/sync.md, "Replacing this Mac's data at pairing"). It runs only while the device is
/// unpaired and has no sync history, so none of its deletions can be published.
///
/// Order: the default role, the default Space (recreated or re-bound with its windows settled),
/// bookmarks, pinned tabs and URL rules in one transaction, the other user Spaces, the agent Spaces
/// of the chosen Profiles, the chosen Profiles and their local rows, stale Space mappings, the
/// settings adoption state; then the postconditions are verified. Every step re-reads state and
/// skips work already done, so a run after a crash or a failed step converges. The rebind also runs
/// again when the row is already re-bound but an earlier attempt left windows of the default Space
/// on a Profile the reset deletes, so those windows are settled again.
///
/// This type deletes data rows; `SyncKeyController.clearLocalSyncState` clears sync metadata. All
/// access goes through injected closures (production wiring: `SyncKeyController.localDataReset()`).
@MainActor
final class PhiLocalDataReset {
    enum SyncHistory: String, Equatable {
        case spaceCursor, profileCursor, marker, ownedItemCursor, profileDeletionJournal
    }

    struct SpaceRow: Equatable {
        let spaceId: String
        let profileId: String
    }

    /// Sync state, wired by `SyncKeyController`.
    struct SyncAccess {
        var isPaired: @MainActor () -> Bool
        /// Unlocked, not retired, still the current account, no reconfiguration pending.
        var isSessionUsable: @MainActor () -> Bool
        /// Empty when there is no sync history. Evidence that cannot be read counts as history.
        var syncHistory: @MainActor () -> [SyncHistory]
        var isProfileMapped: @MainActor (String) -> Bool
        var spaceMappings: @MainActor () -> [String: String]
        var removeSpaceMapping: @MainActor (String) -> Void
        /// Clears the settings `hasAdopted` flag and the per-key sidecars; values stay.
        var clearSettingsAdoption: @MainActor () -> Void
        /// Keeps a Profile the reset deletes from ever being registered to the account
        /// (`SyncKeyController.excludeFromRegistration`), however late a Profile list still names it.
        var excludeFromRegistration: @MainActor (_ profileId: String) -> Void = { _ in }
    }

    /// Local data, wired by `PhiChromiumCoordinator`.
    struct LocalAccess {
        var defaultProfileId = LocalStore.defaultProfileId
        var counts: @MainActor () throws -> PhiDataCounts
        /// Store rows of user Spaces, `default-space` included; agent Spaces excluded.
        var userSpaces: @MainActor () -> [SpaceRow]
        /// Store rows of agent Spaces (ephemeral and persistent).
        var agentSpaces: @MainActor () -> [SpaceRow]
        /// Every Chromium Profile, the agent fallback included. Throws when the list cannot be read.
        var chromiumProfileIds: @MainActor () throws -> Set<String>
        /// The user-assignable subset. Throws when the list cannot be read.
        var userAssignableProfileIds: @MainActor () throws -> Set<String>
        /// Profiles that still have a store row.
        var storedProfileIds: @MainActor () throws -> Set<String>
        var isImporting: @MainActor (_ spaceId: String) -> Bool
        var hasRunningAgentTask: @MainActor (_ spaceIds: Set<String>, _ profileIds: Set<String>) -> Bool
        /// Points the default role at `default-space`; false when not persisted.
        var setDefaultSpaceRole: @MainActor () -> Bool
        var recreateDefaultSpace: @MainActor (_ profileId: String) async throws -> Void
        var rebindDefaultSpace: @MainActor (_ profileId: String) async -> SpaceManager.PairingResetRebind
        /// The Profiles of the live windows currently showing `default-space`.
        var defaultSpaceWindowProfileIds: @MainActor () -> Set<String>
        var wipeOwnedItems: @MainActor () async throws -> Void
        var deleteSpace: @MainActor (_ spaceId: String) async -> SpaceManager.PairingResetSpaceDeletion
        /// Waits (bounded) for window teardown; answers the Profiles that still have a live window.
        var profilesWithLiveWindows: @MainActor (_ profileIds: Set<String>) async -> Set<String>
        var isProfileInUse: @MainActor (_ profileId: String) -> Bool
        /// Deletes the Chromium Profile and its rows; throws the failure (`ProfileDeletionFailure`).
        var deleteProfile: @MainActor (_ profileId: String) async throws -> Void
        /// Removes a deleted Profile's leftover store rows. Idempotent; throws on failure.
        var removeProfileRows: @MainActor (_ profileId: String) async throws -> Void
    }

    private let sync: SyncAccess
    private let local: LocalAccess
    private static let defaultSpaceId = LocalStore.defaultSpaceId

    init(sync: SyncAccess, local: LocalAccess) {
        self.sync = sync
        self.local = local
    }

    func inventory(deleting profileIds: Set<String> = []) throws -> LocalPhiInventory {
        let counts = try readCounts()
        let assignable = try readProfiles(local.userAssignableProfileIds)
        return LocalPhiInventory(
            nonDefaultSpaceIds: nonDefaultSpaceIds(),
            bookmarks: counts.bookmarks, bookmarkFolders: counts.bookmarkFolders,
            pinnedTabs: counts.pinnedTabs, urlRules: counts.urlRules,
            profileIdsToDelete: profileIds.intersection(assignable)
                .subtracting([local.defaultProfileId]).sorted())
    }

    func clear(_ request: LocalResetRequest) async throws {
        let doomed = request.deleteProfileIds
        try checkPreconditions(request)

        // 1. The role sits on `default-space` before any other Space goes, so no hand-off runs.
        guard local.setDefaultSpaceRole() else { throw PhiLocalDataResetError.roleNotPersisted }

        // 2. The store keeps at least one user Space: recreate `default-space` if it was deleted.
        if !local.userSpaces().contains(where: { $0.spaceId == Self.defaultSpaceId }) {
            do { try await local.recreateDefaultSpace(local.defaultProfileId) } catch {
                throw PhiLocalDataResetError.defaultSpaceUnavailable
            }
        }
        guard let defaultSpace = local.userSpaces().first(where: { $0.spaceId == Self.defaultSpaceId }) else {
            throw PhiLocalDataResetError.defaultSpaceUnavailable
        }

        // 3. Never strand the default Space, or its windows, on a Profile this reset deletes. The row
        // may already be re-bound by an earlier attempt whose windows did not settle; the rebind then
        // runs again to settle them.
        if doomed.contains(defaultSpace.profileId)
            || !doomed.isDisjoint(with: local.defaultSpaceWindowProfileIds()) {
            try ensureStillSafe()
            let outcome = await local.rebindDefaultSpace(local.defaultProfileId)
            guard outcome == .rebound else { throw PhiLocalDataResetError.defaultSpaceRebindRefused(outcome) }
        }

        // 4. Bookmarks, pinned tabs and URL rules, in one transaction.
        try ensureStillSafe()
        if try readCounts().ownedItemRows > 0 {
            try await local.wipeOwnedItems()
        }

        // 5. Every other user Space, then the agent Spaces of the chosen Profiles (device-local, and
        // their Profile's Chromium data goes anyway), each with its windows. Before step 6, or a
        // deleted Profile's Spaces would be stranded.
        let doomedAgentSpaceIds = { self.local.agentSpaces().filter { doomed.contains($0.profileId) }.map(\.spaceId).sorted() }
        for spaceId in nonDefaultSpaceIds() + doomedAgentSpaceIds() {
            try ensureStillSafe()
            let outcome = await local.deleteSpace(spaceId)
            guard outcome == .deleted || outcome == .notFound else {
                throw PhiLocalDataResetError.spaceDeletionRefused(spaceId: spaceId, outcome: outcome)
            }
        }

        // 6. The chosen Profiles. No window may still be bound to one: window teardown is
        // asynchronous, so wait for it (bounded) and fail closed if a window remains. One already gone
        // from Chromium was deleted by an earlier attempt; its leftover rows are swept either way.
        let chromium = try readProfiles(local.chromiumProfileIds)
        let present = doomed.intersection(chromium)
        // Before any deletion: a mapping pass that read the Profile list earlier must not register
        // a Profile deleted here once enrollment opens the gate.
        for profileId in present.sorted() { sync.excludeFromRegistration(profileId) }
        if let live = await local.profilesWithLiveWindows(present).sorted().first {
            throw PhiLocalDataResetError.liveWindowsOnDeletedProfile(live)
        }
        for profileId in doomed.sorted() {
            if present.contains(profileId) {
                try ensureStillSafe()
                guard !sync.isProfileMapped(profileId) else { throw PhiLocalDataResetError.profileMapped(profileId) }
                guard !local.isProfileInUse(profileId) else { throw PhiLocalDataResetError.profileInUse(profileId) }
                do { try await local.deleteProfile(profileId) } catch {
                    throw PhiLocalDataResetError.profileDeletionFailed(
                        profileId, reason: (error as? ProfileDeletionFailure)?.reasonText ?? String(describing: error))
                }
            }
            do { try await local.removeProfileRows(profileId) } catch {
                throw PhiLocalDataResetError.profileRowCleanupFailed(profileId)
            }
        }

        // 7. Space mappings left by an earlier partial setup for rows that no longer exist.
        try ensureStillSafe()
        let liveSpaceIds = Set(local.userSpaces().map(\.spaceId))
        for spaceId in sync.spaceMappings().keys.sorted() where !liveSpaceIds.contains(spaceId) {
            sync.removeSpaceMapping(spaceId)
        }

        // Settings keep their values; the first pull adopts the account's settings wholesale again.
        try ensureStillSafe()
        sync.clearSettingsAdoption()

        try verifyPostconditions(request)
    }

    // MARK: - Preconditions and postconditions

    private func checkPreconditions(_ request: LocalResetRequest) throws {
        // P1
        guard !sync.isPaired() else { throw PhiLocalDataResetError.paired }
        guard sync.isSessionUsable() else { throw PhiLocalDataResetError.sessionUnavailable }
        // P2
        if let history = sync.syncHistory().first { throw PhiLocalDataResetError.syncHistoryPresent(history) }
        // P4. An id Chromium no longer lists was deleted by an earlier attempt and is only swept.
        let chromium = try readProfiles(local.chromiumProfileIds)
        let assignable = try readProfiles(local.userAssignableProfileIds)
        for profileId in request.deleteProfileIds.sorted() {
            guard profileId != local.defaultProfileId else {
                throw PhiLocalDataResetError.profileNotDeletable(profileId)
            }
            guard chromium.contains(profileId) else { continue }
            guard assignable.contains(profileId) else { throw PhiLocalDataResetError.profileNotDeletable(profileId) }
            guard !sync.isProfileMapped(profileId) else { throw PhiLocalDataResetError.profileMapped(profileId) }
        }
        // P3
        let spaces = local.userSpaces() + local.agentSpaces()
        guard !spaces.contains(where: { local.isImporting($0.spaceId) }) else {
            throw PhiLocalDataResetError.importInProgress
        }
        let doomedSpaceIds = Set(local.userSpaces().map(\.spaceId)).subtracting([Self.defaultSpaceId])
        guard !local.hasRunningAgentTask(doomedSpaceIds, request.deleteProfileIds) else {
            throw PhiLocalDataResetError.agentTaskRunning
        }
    }

    /// Re-checked before every destructive step: nothing may be deleted once the device is paired,
    /// the account switched, the controller was retired, or an import started.
    private func ensureStillSafe() throws {
        guard !sync.isPaired() else { throw PhiLocalDataResetError.paired }
        guard sync.isSessionUsable() else { throw PhiLocalDataResetError.sessionUnavailable }
        guard !(local.userSpaces() + local.agentSpaces()).contains(where: { local.isImporting($0.spaceId) }) else {
            throw PhiLocalDataResetError.importInProgress
        }
    }

    private func verifyPostconditions(_ request: LocalResetRequest) throws {
        let doomed = request.deleteProfileIds
        guard try readCounts() == PhiDataCounts() else {
            throw PhiLocalDataResetError.postconditionFailed("owned items or user Spaces remain")
        }
        let spaces = local.userSpaces()
        guard spaces.map(\.spaceId) == [Self.defaultSpaceId] else {
            throw PhiLocalDataResetError.postconditionFailed("default-space is not the only user Space")
        }
        guard !doomed.contains(spaces[0].profileId) else {
            throw PhiLocalDataResetError.postconditionFailed("default-space is bound to a deleted Profile")
        }
        guard !local.agentSpaces().contains(where: { doomed.contains($0.profileId) }) else {
            throw PhiLocalDataResetError.postconditionFailed("an agent Space of a deleted Profile remains")
        }
        guard try readProfiles(local.chromiumProfileIds).isDisjoint(with: doomed) else {
            throw PhiLocalDataResetError.postconditionFailed("a chosen Profile still exists")
        }
        guard try readProfiles(local.storedProfileIds).isDisjoint(with: doomed) else {
            throw PhiLocalDataResetError.postconditionFailed("a chosen Profile's store row remains")
        }
        guard sync.spaceMappings().keys.allSatisfy({ $0 == Self.defaultSpaceId }) else {
            throw PhiLocalDataResetError.postconditionFailed("a Space mapping remains")
        }
        guard !sync.isPaired(), sync.syncHistory().isEmpty else {
            throw PhiLocalDataResetError.postconditionFailed("sync state changed during the reset")
        }
    }

    private func readCounts() throws -> PhiDataCounts {
        do { return try local.counts() } catch { throw PhiLocalDataResetError.inventoryUnavailable }
    }

    private func readProfiles(_ read: @MainActor () throws -> Set<String>) throws -> Set<String> {
        do { return try read() } catch { throw PhiLocalDataResetError.inventoryUnavailable }
    }

    private func nonDefaultSpaceIds() -> [String] {
        local.userSpaces().map(\.spaceId).filter { $0 != Self.defaultSpaceId }.sorted()
    }
}

extension PhiLocalDataReset: LocalPhiResetting {}

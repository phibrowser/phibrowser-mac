// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

/// Value snapshot of one local user Profile as the Profile entity sees it. Only Profiles mapped
/// to an account Profile ever become one (`PhiProfileLocalAccess.currentProfiles()`).
struct PhiLocalProfile: Equatable {
    var profileId: String
    var displayName: String
    /// Epoch ms of `ProfileModel.createdDate`, 0 when this device never recorded one.
    var createdAtMs: Int64
}

/// The local facts `SyncableProfiles.tombstoneDecision` weighs for one Profile.
struct ProfileDeletionBlockers: Equatable {
    /// The Default Profile is never deleted.
    var isDefaultProfile = false
    /// Account sync uuid of every live (not remotely soft-deleted) user Space bound to the
    /// Profile; nil for one with no Space mapping.
    var liveUserSpaceSyncUuids: [String?] = []
    /// A persistent agent Space is bound to the Profile: it blocks a local deletion as a user
    /// Space does.
    var hasPersistentAgentSpace = false
    /// A running (non-persistent) agent Space is bound to the Profile: it goes away by itself.
    var hasRunningAgentSpace = false
    /// An import is writing into one of its Spaces.
    var isImporting = false
}

/// What a remote Profile tombstone does on this device.
enum ProfileTombstoneDecision: Equatable {
    case delete
    /// Retry next round.
    case deferApply
    /// The Profile cannot go here: republish the entity ("edit beats delete").
    case undelete
}

/// Profile-side snapshot and merge for the Profile entity (docs/sync.md, "Profile entity").
/// Pure functions, like `SyncableSpaces`: the engine owns all persistence.
enum SyncableProfiles {

    // MARK: - Snapshot

    /// The outgoing entity for every mapped user Profile, keyed by account profile uuid.
    ///
    /// Left out: Profiles with no mapping (never published: unmapped, Phi Chat and agent fallback
    /// Profiles are filtered at the source as well), and uuids whose cursor is deleted, being
    /// deleted, holds a deferred remote tombstone or a parked entity -- a uuid this device cannot
    /// reconcile is one it must not publish over.
    ///
    /// The name follows the local name only when the USER renamed the Profile here: a local name
    /// equal to `localNameAtBaseline` (or a cursor that has not recorded one yet) echoes the
    /// baseline's name and stamp, so a device whose Profile carries a suffixed twin name ("Work (2)")
    /// never renames the account Profile. With no baseline -- the first publication after the drain
    /// -- the local name is published at stamp 0, so a derived name never beats a real rename.
    /// A real rename is stamped through the same three-branch rule as `SyncableSpaces.stamped`.
    static func snapshot(profiles: [PhiLocalProfile],
                         table: PhiSpaceSyncTable,
                         globalUuid: (String) -> String?,
                         now: Int64) -> [String: Phi_PhiProfileEntity] {
        var out: [String: Phi_PhiProfileEntity] = [:]
        for profile in profiles {
            guard let uuid = globalUuid(profile.profileId), !uuid.isEmpty else { continue }
            let cursor = table.profileCursors[uuid]
            if let cursor {
                guard !cursor.pendingDelete, !cursor.pendingTombstone, cursor.deletedAtMs == nil,
                      cursor.purgedAtMs == nil, cursor.pendingApply == nil else { continue }
            }
            let baseline = cursor?.reconciled.flatMap { try? Phi_PhiProfileEntity(serializedBytes: $0) }
            let pending = baseline == nil ? nil
                : cursor?.pendingProjection.flatMap { try? Phi_PhiProfileEntity(serializedBytes: $0) }

            var entity = Phi_PhiProfileEntity()
            entity.profileUuid = uuid
            if let baseline {
                let localNameAtBaseline = cursor?.localNameAtBaseline
                if localNameAtBaseline == nil || localNameAtBaseline == profile.displayName {
                    entity.name = baseline.name
                } else {
                    entity.name = stamped(string(profile.displayName), baseline.name, pending?.name, now)
                }
            } else {
                var name = string(profile.displayName)
                name.updatedAtMs = 0
                entity.name = name
            }
            entity.createdAtMs = profile.createdAtMs
            out[uuid] = entity
        }
        return out
    }

    private static func string(_ s: String) -> Phi_PhiSettingValue {
        var v = Phi_PhiSettingValue()
        v.stringValue = s
        return v
    }

    /// `SyncableSpaces.stamped`'s rule: equal to the baseline -> the baseline's stamp; equal to the
    /// stamp this device already recorded -> that stamp; otherwise a new edit, stamped `now` but
    /// never below the value it overwrites (AM-1).
    private static func stamped(_ value: Phi_PhiSettingValue,
                                _ baseline: Phi_PhiSettingValue,
                                _ pending: Phi_PhiSettingValue?,
                                _ now: Int64) -> Phi_PhiSettingValue {
        var out = value
        let signature = SyncableSettings.signature(of: value)
        if SyncableSettings.signature(of: baseline) == signature {
            out.updatedAtMs = baseline.updatedAtMs
        } else if let pending, SyncableSettings.signature(of: pending) == signature {
            out.updatedAtMs = pending.updatedAtMs
        } else {
            out.updatedAtMs = PhiHybridClock.editStamp(
                editWallMs: now, overwrittenStampMs: (pending ?? baseline).updatedAtMs)
        }
        return out
    }

    // MARK: - Merge

    /// LWW through the shared winner for `name`, `min()` of the non-zero values for
    /// `created_at_ms`, identity for `profile_uuid`. Starts from `remote` so a newer client's
    /// reserved fields 4-7 survive a round trip through this build (Proto/README.md).
    static func merge(local: Phi_PhiProfileEntity, remote: Phi_PhiProfileEntity) -> Phi_PhiProfileEntity {
        var merged = remote
        merged.profileUuid = local.profileUuid.isEmpty ? remote.profileUuid : local.profileUuid
        merged.name = SyncableSettings.lwwWinner(local.name, remote.name)
        let candidates = [local.createdAtMs, remote.createdAtMs].filter { $0 > 0 }
        merged.createdAtMs = candidates.min() ?? 0
        return merged
    }

    // MARK: - Remote tombstone (docs/sync.md, "Profile deletion and rename")

    /// Whether a remote Profile tombstone deletes the local Profile here. The Default Profile and a
    /// Profile that still has a live user Space are kept and the entity republished: edit beats
    /// delete, and Spaces are never rebound elsewhere; a persistent agent Space counts as one. A
    /// Space whose own deletion is still pending here, a running agent Space or an import in
    /// flight defers the decision to a later round (bounded by the engine).
    static func tombstoneDecision(_ blockers: ProfileDeletionBlockers,
                                  table: PhiSpaceSyncTable) -> ProfileTombstoneDecision {
        if blockers.isDefaultProfile { return .undelete }
        if blockers.hasPersistentAgentSpace { return .undelete }
        var deferApply = blockers.hasRunningAgentSpace || blockers.isImporting
        for uuid in blockers.liveUserSpaceSyncUuids {
            guard let uuid, let cursor = table.cursors[uuid] else { return .undelete }
            if cursor.hidden || cursor.deletedAtMs != nil || cursor.purgedAtMs != nil { continue }
            if cursor.pendingTombstone || cursor.pendingDelete { deferApply = true; continue }
            return .undelete
        }
        return deferApply ? .deferApply : .delete
    }
}

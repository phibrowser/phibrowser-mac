// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

/// Complete bridge from the default-Space ROLE to a synced setting (C1 / R1.2 option A).
/// The role — "which Space windows opened without context land on, the app-chrome theme anchor,
/// the pre-selected import target" — lives in `AccountUserDefaults.DefaultsKey.defaultSpaceId`
/// as a LOCAL spaceId, read by `SpaceManager.currentDefaultSpaceId` and moved by the hand-off
/// inside `SpaceManager.deleteSpace`. Local ids never reach the wire (D6 §2.4), so the account
/// carries the role as the holder's Space sync uuid in one LWW register.
/// This is `PinnedTabScopeMirror` applied to a second non-preference account value; nothing
/// about the M3-1 settings channel changes:
/// 1. Add this ordinary defaultSpace SyncableSetting to SyncableSettings.all.
/// 2. Local to mirror: write the mirror key at the hand-off in `deleteSpace`.
/// 3. Reseed via reseed(localUuid:into:) on every account mount.
/// 4. Mirror to local: the coordinator's phiSyncedSettingsDidApply observer resolves the uuid
///    and hands it to `SpaceManager.applyAccountDefaultSpace(syncUuid:)`.
/// The IDENTITY `"default-space"` is unrelated to the role: D1's `profile_uuid` / `theme_id`
/// suppressions stay attached to that uuid wherever the role happens to sit (R1.1).
/// Keep this separate from SyncableSettings.swift so tests can call reseed directly.
enum PhiDefaultSpaceMirror {

    /// Preference mirror and wire-map key. The value is the ACCOUNT sync uuid of the role
    /// holder, in UserDefaults.standard beside the other synced settings — never a local
    /// spaceId, which is device-private (D6 §2.4).
    static let key = "PhiDefaultSpaceUuid"

    /// An ordinary synced setting, following `PinnedTabScopeMirror.pinnedTabScope`.
    /// read returns nil for a missing or empty value, so snapshot skips the key entirely and a
    /// device that has never published a role cannot overwrite the account's.
    /// write accepts ANY non-empty string and deliberately does NOT check that the uuid
    /// resolves to a local Space: a joining device must be able to store the account's answer
    /// before its own Spaces are paired. Resolution happens at read time, and a register this
    /// device cannot honour falls back without ever writing back (R1.4).
    static let defaultSpace = SyncableSetting(
        key: key,
        read: { defaults in
            guard let uuid = defaults.string(forKey: key), !uuid.isEmpty else { return nil }
            var value = Phi_PhiSettingValue()
            value.stringValue = uuid
            return value
        },
        write: { value, defaults in
            guard case .stringValue(let uuid) = value.v, !uuid.isEmpty else { return }
            defaults.set(uuid, forKey: key)
        }
    )

    /// Reseed outcomes let the caller decide whether to apply the register locally. reseed is
    /// synchronous and touches nothing but `defaults`, so tests can call it directly.
    enum ReseedOutcome: Equatable {
        /// Key matches the local pointer's account identity: no writes.
        case noop
        /// Key was absent: seeded it and both sidecars at stamp 0.
        case seeded
        /// Key names a different holder than the local pointer. The key is authoritative:
        /// leave it intact and apply it to the local pointer.
        case applyRegister(uuid: String)
    }

    /// Reseed the mirror key when mounting an account.
    /// - Missing mirror key: write `localUuid` (or the well-known default identity when the
    ///   local pointer has no account identity) and both matching sidecars; return seeded.
    /// - Mirror differs from the local pointer: keep the account value and return
    ///   applyRegister.
    /// - Mirror matches: leave key and sidecars untouched; return noop.
    /// Invariant: reseed never clears sidecars, for the same reason
    /// `PinnedTabScopeMirror.reseed` documents — a cleared sidecar makes the next snapshot read
    /// the seed back as a local edit and stamp it `now`, which would let a device returning
    /// from two offline weeks move the role account-wide.
    /// The mirror key lives in device-wide `UserDefaults.standard` while the local pointer is
    /// account-scoped, so a mismatch cannot distinguish cross-account interference from a
    /// landed account value whose local application was interrupted. Trusting the key converges
    /// in both cases: the next snapshot of the account that owns it corrects the register, and
    /// applying it locally is idempotent and never written back when it does not resolve.
    /// - Parameters:
    ///   - localUuid: the account sync uuid of the Space the local pointer names, or nil when
    ///     the pointer names a Space with no account identity (unmapped, or no mapping layer).
    ///   - defaults: preference domain holding the mirror key (UserDefaults.standard in
    ///     production).
    static func reseed(localUuid: String?, into defaults: UserDefaults) -> ReseedOutcome {
        guard let mirrored = defaults.string(forKey: key), !mirrored.isEmpty else {
            seed(localUuid ?? SyncableSpaces.defaultSpaceUuid, into: defaults)
            return .seeded
        }
        guard mirrored != localUuid else { return .noop }
        return .applyRegister(uuid: mirrored)
    }

    /// Seed the key and both sidecars together.
    /// Use timestamp 0, not now, exactly as `PinnedTabScopeMirror.seed` does: seeding
    /// represents no user action, so it must lose to any real hand-off stamped at edit time,
    /// and two devices seeding different uuids at 0 still converge through `lwwWinner`'s
    /// device-independent byte tie-break.
    private static func seed(_ uuid: String, into defaults: UserDefaults) {
        var value = Phi_PhiSettingValue()
        value.stringValue = uuid
        defaults.set(uuid, forKey: key)
        defaults.set(NSNumber(value: Int64(0)), forKey: SyncableSettings.timestampKey(for: key))
        defaults.set(SyncableSettings.signature(of: value),
                     forKey: SyncableSettings.valueKey(for: key))
    }
}

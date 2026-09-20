// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

/// Complete bridge from pin scope to a synced setting (§7.1).
/// Scope lives in the SwiftData singleton BrowserDataSettingsModel.pinnedTabScopeRawValue, read by
/// LocalStore.pinnedTabScope(in:) and changed by
/// LocalStore.changePinnedTabScope(to:preferredProfileId:preferredSpaceId:). SyncableSetting's read/write
/// closures are synchronous and take UserDefaults, while LocalStore reads on the main actor and writes
/// asynchronously.
/// Use a preference mirror and a landing observer to bridge them without changing the M3-1 settings channel:
/// 1. Add this ordinary pinnedTabScope SyncableSetting to SyncableSettings.all.
/// 2. Local to mirror: write the mirror key at the end of a successful changePinnedTabScope.
/// 3. Reseed via reseed(rowValue:into:) on every account mount (R-M3-3-8).
/// 4. Mirror to local: the coordinator's phiSyncedSettingsDidApply observer runs the existing local migration.
/// The engine reads through PhiPinnedTabLocalAccess.accountScope(), the sole §7.3 scope-mismatch interface,
/// rather than this key directly.
/// Keep this separate from SyncableSettings.swift so tests can call reseed directly.
enum PinnedTabScopeMirror {

    /// Preference mirror and wire-map key. The value is PinnedTabScope.rawValue (space/profile/app) in
    /// UserDefaults.standard, shared with other synced settings and read by AccountPhiPinnedTabAccess.
    /// AccountPhiPinnedTabAccess intentionally keeps a read-only copy without importing this type; the key
    /// name is the only coupling between reader and writer.
    static let key = "PhiPinnedTabScope"

    /// An ordinary synced setting, following SyncableSettings.layoutMode.
    /// read returns nil for a missing or unrecognized value, so snapshot skips the key entirely. An
    /// unpublished account scope differs from profile; defaulting to profile could publish it from a
    /// Space-scoped device. Only reseed introduces this key.
    /// write validates PinnedTabScope(rawValue:) and silently discards unknown values from newer peers.
    /// SyncableSettings.apply then detects a readback mismatch and leaves the sidecar unchanged, so the next
    /// round republishes the local value rather than marking it synced.
    static let pinnedTabScope = SyncableSetting(
        key: key,
        read: { defaults in
            guard let raw = defaults.string(forKey: key),
                  PinnedTabScope(rawValue: raw) != nil else { return nil }
            var value = Phi_PhiSettingValue()
            value.stringValue = raw
            return value
        },
        write: { value, defaults in
            guard case .stringValue(let raw) = value.v,
                  PinnedTabScope(rawValue: raw) != nil else { return }
            defaults.set(raw, forKey: key)
        }
    )

    /// Reseed outcomes let the caller decide whether to migrate. reseed is synchronous and avoids SwiftData so
    /// tests can call it directly.
    enum ReseedOutcome: Equatable {
        /// Key matches the row: no writes.
        case noop
        /// Key was absent: seeded it and both sidecars from the row.
        case seeded
        /// Key differs from the row: leave it intact and rerun local migration to this mirror value.
        case runLocalMigration(to: PinnedTabScope)
        /// Row cannot be read: no writes or migration this round. See reseed's rowValue contract.
        case rowUnavailable
    }

    /// Reseed the mirror key when mounting an account (R-M3-3-8 / I12 / L4).
    /// - Unreadable row (nil rowValue): no writes or migration; return rowUnavailable.
    /// - Missing mirror key: write the row value and both matching sidecars together; return seeded.
    /// - Mirror differs from row: keep the authoritative account value and return runLocalMigration.
    /// - Mirror matches row: leave key and sidecars untouched; return noop.
    /// Invariant: reseed never clears sidecars. Otherwise the next snapshot treats seeding as a new local edit
    /// and stamps now. A device returning after two offline weeks could roll account scope back and trigger
    /// full pin migrations everywhere.
    /// A mismatch cannot distinguish cross-account interference (UserDefaults.standard is device-wide;
    /// BrowserDataSettingsModel is per-account) from an applied account value whose migration was interrupted
    /// or failed. The guard currentScope != newScope leaves no row evidence of that failure. Replacing the key
    /// from the row would erase the just-landed account value and defeat §11.4 retries. Trusting the key and
    /// rerunning migration also converges after cross-account interference: the next account snapshot corrects
    /// it, at worst causing one extra migration.
    /// Nil rowValue means unreadable, never profile. LocalStore.pinnedTabScope() defaults to profile when the
    /// database cannot open after compatibility rejection, requiresNewerApp, or ModelContainer failure, yet
    /// the engine still gets built. Seeding that failure default could establish profile on an account with no
    /// published scope, migrate every device, and later migrate this device's real pins when its database
    /// opens. AccountPhiPinnedTabAccess.accountScope() avoids the same fallback. Leave everything untouched on
    /// read failure and retry on the next mount.
    /// - Parameters:
    ///   - rowValue: Current SwiftData singleton scope; pass nil if unreadable.
    ///   - defaults: Preference domain containing the mirror key (UserDefaults.standard in production).
    static func reseed(rowValue: PinnedTabScope?, into defaults: UserDefaults) -> ReseedOutcome {
        guard let rowValue else { return .rowUnavailable }
        guard let raw = defaults.string(forKey: key),
              let mirrored = PinnedTabScope(rawValue: raw) else {
            seed(rowValue, into: defaults)
            return .seeded
        }
        guard mirrored != rowValue else { return .noop }
        return .runLocalMigration(to: mirrored)
    }

    /// Seed the key and both sidecars together.
    /// Use timestamp 0, not now. Sidecars prevent snapshot from mistaking seeding for a local edit; now would
    /// let a device's default beat a real remote scope change. Seeding represents no user action, so 0
    /// correctly loses to any real edit stamped now through §7.1 step 2. If the account has no value, this
    /// still publishes normally. Simultaneous different seeds at 0 converge through lwwWinner's
    /// device-independent byte tie-break.
    private static func seed(_ scope: PinnedTabScope, into defaults: UserDefaults) {
        var value = Phi_PhiSettingValue()
        value.stringValue = scope.rawValue
        defaults.set(scope.rawValue, forKey: key)
        defaults.set(NSNumber(value: Int64(0)), forKey: SyncableSettings.timestampKey(for: key))
        defaults.set(SyncableSettings.signature(of: value),
                     forKey: SyncableSettings.valueKey(for: key))
    }
}

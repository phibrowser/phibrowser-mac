// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

/// Sync fields of the launch-time `user_defaults_snapshot` (docs/sync.md, "Launch snapshot caches").
///
/// The snapshot is captured before the account, the key controller or the account key exist, so
/// the sync layer mirrors what it already learns into UserDefaults and the snapshot reads the
/// mirror. Telemetry only: no sync decision ever reads these keys. The Profile listing and the
/// default-flag map hold account Profile uuids as keys, locally only; the snapshot reports counts
/// and one bool, never a uuid.
enum SyncLaunchAnalytics {
    static let enabledDefaultsKey = "metrics.sync.enabled"
    static let activeDeviceCountDefaultsKey = "metrics.sync.activeDeviceCount"
    static let accountProfileUuidsDefaultsKey = "metrics.sync.accountProfileUuids"
    static let defaultFlagsDefaultsKey = "metrics.sync.profileDefaultFlags"
    /// Envelope reads one mapping pass may spend on uuids whose flag was never read.
    static let defaultFlagFillPerPass = 3

    /// Serializes read-modify-write of the flag map: envelope reads finish concurrently.
    private static let lock = NSLock()

    /// The pairing gate's `isPaired`, every time enrollment is configured or changes.
    static func recordPaired(_ paired: Bool, defaults: UserDefaults = .standard) {
        guard defaults.object(forKey: enabledDefaultsKey) as? Bool != paired else { return }
        defaults.set(paired, forKey: enabledDefaultsKey)
    }

    /// Active (not revoked) devices in the account, from a device listing.
    static func recordActiveDeviceCount(_ count: Int, defaults: UserDefaults = .standard) {
        guard defaults.object(forKey: activeDeviceCountDefaultsKey) as? Int != count else { return }
        defaults.set(count, forKey: activeDeviceCountDefaultsKey)
    }

    /// The rule the Devices pane shows: active and not revoked.
    static func activeDeviceCount(_ rows: [AccountDeviceDTO]) -> Int {
        rows.filter { $0.status == "active" && $0.revokedAt == nil }.count
    }

    /// The account's Profile uuids from a listing. Flags of uuids no longer listed are dropped.
    static func recordAccountProfiles(_ uuids: Set<String>, defaults: UserDefaults = .standard) {
        lock.lock(); defer { lock.unlock() }
        let sorted = uuids.sorted()
        if defaults.stringArray(forKey: accountProfileUuidsDefaultsKey) != sorted {
            defaults.set(sorted, forKey: accountProfileUuidsDefaultsKey)
        }
        let flags = storedFlags(defaults)
        let kept = flags.filter { uuids.contains($0.key) }
        if kept != flags { defaults.set(kept, forKey: defaultFlagsDefaultsKey) }
    }

    /// One decrypted Profile envelope's default flag; an envelope without the flag is not default.
    static func recordDefaultFlag(uuid: String, isDefault: Bool, defaults: UserDefaults = .standard) {
        lock.lock(); defer { lock.unlock() }
        var flags = storedFlags(defaults)
        guard flags[uuid] != isDefault else { return }
        flags[uuid] = isDefault
        defaults.set(flags, forKey: defaultFlagsDefaultsKey)
    }

    /// Listed uuids whose flag was never read, in uuid order, at most `limit`, skipping `excluded`
    /// (envelopes that do not open, which would otherwise be re-read every pass).
    static func uuidsNeedingDefaultFlag(listing: Set<String>, excluded: Set<String> = [],
                                        limit: Int = defaultFlagFillPerPass,
                                        defaults: UserDefaults = .standard) -> [String] {
        let flags = storedFlags(defaults)
        return Array(listing.subtracting(excluded).filter { flags[$0] == nil }.sorted().prefix(limit))
    }

    /// Sign-out or this device leaving sync: nothing cached describes the next account.
    static func reset(defaults: UserDefaults = .standard) {
        lock.lock(); defer { lock.unlock() }
        defaults.set(false, forKey: enabledDefaultsKey)
        for key in [activeDeviceCountDefaultsKey, accountProfileUuidsDefaultsKey, defaultFlagsDefaultsKey] {
            defaults.removeObject(forKey: key)
        }
    }

    /// `sync_enabled` always. The counts only while enabled and known; an unknown count is
    /// omitted, never reported as 0. The default-flag count is known once every listed Profile's
    /// flag has been read.
    static func snapshotProperties(defaults: UserDefaults = .standard) -> [String: Any] {
        let enabled = defaults.object(forKey: enabledDefaultsKey) as? Bool ?? false
        var properties: [String: Any] = ["sync_enabled": enabled]
        guard enabled else { return properties }
        if let devices = defaults.object(forKey: activeDeviceCountDefaultsKey) as? Int {
            properties["sync_paired_device_count"] = devices
        }
        if let listing = defaults.stringArray(forKey: accountProfileUuidsDefaultsKey) {
            properties["sync_account_profile_count"] = listing.count
            let flags = storedFlags(defaults)
            if listing.allSatisfy({ flags[$0] != nil }) {
                properties["sync_default_flagged_profile_count"] = listing.filter { flags[$0] == true }.count
            }
        }
        return properties
    }

    private static func storedFlags(_ defaults: UserDefaults) -> [String: Bool] {
        defaults.dictionary(forKey: defaultFlagsDefaultsKey) as? [String: Bool] ?? [:]
    }
}

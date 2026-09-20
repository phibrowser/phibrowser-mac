// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

/// Persistence for local spaceId → account sync UUID (D6 / M3-2b §2.1), the Space counterpart of
/// ProfileSyncMappingStore without cryptography: Spaces have no per-entity envelope, and minting is a local
/// write.
///
/// Invariants (§2.4): never rewrite local spaceId; never put syncUuid in local rows. This table is the sole
/// bridge between namespaces; LocalStorage and SpaceManager know nothing about it.
protocol SpaceSyncMappingStore {
    func syncUuid(forSpaceId spaceId: String) -> String?
    /// No discardable result: both callers (SpaceSyncMappingManager.mintSyncUuid/map) must throw on false.
    /// Publishing an unpersisted UUID would lose its mapping at restart and mint another identity for the same
    /// Space (R-M3-4a-83).
    func setSyncUuid(_ uuid: String, forSpaceId spaceId: String) -> Bool
    /// `[localSpaceId: syncUuid]`
    func allMappings() -> [String: String]
    /// Remove a mapping after its local row disappears via tombstone applied or 30-day purge, avoiding reverse
    /// lookup of nonexistent Spaces (§2.3).
    ///
    /// Keep Void: AccountUserDefaults.set rolls back memory on persistence failure, preserving the mapping
    /// consistently with disk. Consumers already converge through PhiSyncEngine.dropSpaceMapping's
    /// dead-mapping repair and SyncKeyController self-revocation, so no result is needed.
    func removeMapping(forSpaceId spaceId: String)
    /// Clear the whole table for self-revocation (§2.3), never partially or by bypassing this store to write
    /// AccountUserDefaults directly. Remains Void for the same rollback reason.
    func removeAllMappings()
}

/// Mapping table beside sync.profileGlobalUuids in the account plist. AccountUserDefaults writes
/// users/<userID>/defaults/account_defaults.plist, providing account isolation without switch-time cleanup.
final class AccountSpaceSyncMappingStore: SpaceSyncMappingStore {
    static let defaultsKey = "sync.spaceGlobalUuids"
    private let defaults: AccountUserDefaults

    init(defaults: AccountUserDefaults) {
        self.defaults = defaults
    }

    func syncUuid(forSpaceId spaceId: String) -> String? { allMappings()[spaceId] }

    func setSyncUuid(_ uuid: String, forSpaceId spaceId: String) -> Bool {
        var map = allMappings()
        map[spaceId] = uuid
        return defaults.set(map, forCodableKey: Self.defaultsKey)
    }

    func allMappings() -> [String: String] {
        defaults.codableValue(forKey: Self.defaultsKey) ?? [:]
    }

    func removeMapping(forSpaceId spaceId: String) {
        var map = allMappings()
        guard map.removeValue(forKey: spaceId) != nil else { return }
        defaults.set(map, forCodableKey: Self.defaultsKey)
    }

    func removeAllMappings() {
        defaults.set([String: String](), forCodableKey: Self.defaultsKey)
    }
}

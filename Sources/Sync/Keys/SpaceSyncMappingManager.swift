// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

/// alreadyMapped is the same protection as ProfileKeyManagerError.alreadyMapped
/// (ProfileKeyManager.swift:5-10): refuse minting after a transient lookup failure is mistaken for no mapping.
/// Minting again would abandon the existing account entity and permanently split devices.
enum SpaceSyncMappingError: Error, Equatable {
    case alreadyMapped
    /// Another local Space already claimed this syncUuid. Enforce injectivity at the write boundary, not
    /// through later tie-breaks.
    case syncUuidAlreadyClaimed
    /// Default Space uses a constant identity without a stored mapping (R-D6-2).
    case defaultSpaceIsImplicit
    /// This controller has no mapping layer (spaceKeys == nil). Publish nothing and expose unmapped counts
    /// (§9.3); never substitute an in-memory table.
    case mappingLayerUnavailable
    /// Persistence failure restores the prior in-memory store (R-M3-4a-83). The failed mapping is absent from
    /// both forward and reverse lookup after throwing.
    case persistFailed
    /// Reserved local IDs under the incognito prefix (R-M3-4a-6). Mapping one would treat
    /// incognitoRuleTargetId as a real Space for eligibility/retention cascade despite having no SpaceModel
    /// row or cursor.
    case reservedSpaceId
    /// Reserved account UUIDs defaultSpaceUuid/incognitoSpaceUuid (R-M3-4a-6). Binding one to a real local
    /// Space would silently make devices resolve the same incognito rule to different targets.
    case reservedSyncUuid
}

/// Local spaceId ↔ account syncUuid translation (D6 §2.1), analogous to ProfileKeyManager without API/key
/// management.
///
/// Invariants (§2.4): never rewrite local spaceId; never put syncUuid in local rows. The spec requires these
/// in both this type and AccountSpaceSyncMappingStore's protocol header, because this type holds strings from
/// both namespaces.
///
/// Default Space uses constant branches in both resolvers, never a mapping row (R-D6-2). Self-revocation
/// clears all mappings; a stored default mapping could disappear and be queried before reseeding on rejoin,
/// permanently skipping default-Space updates. Two local constant branches make its identity indestructible.
@MainActor
final class SpaceSyncMappingManager {
    private let store: any SpaceSyncMappingStore

    init(store: any SpaceSyncMappingStore) {
        self.store = store
    }

    /// Outbound translation: return the default-Space constant without a table lookup.
    func syncUuid(forSpaceId spaceId: String) -> String? {
        if spaceId == LocalStore.defaultSpaceId { return SyncableSpaces.defaultSpaceUuid }
        return store.syncUuid(forSpaceId: spaceId)
    }

    /// Inbound translation: for duplicate matches, warn and choose the lexicographically smallest local ID.
    /// This diagnoses rather than repairs; map(spaceId:toSyncUuid:) enforces injectivity. Matches
    /// ProfileKeyManager.localProfileId (ProfileKeyManager.swift:183-192).
    func localSpaceId(forSyncUuid uuid: String) -> String? {
        if uuid == SyncableSpaces.defaultSpaceUuid { return LocalStore.defaultSpaceId }
        let matches = store.allMappings().filter { $0.value == uuid }.keys.sorted()
        if matches.count > 1 {
            AppLogWarn("[phi-sync] \(matches.count) local Spaces map to one account Space; taking the lexicographically smallest")
        }
        return matches.first
    }

    /// Wizard join-as-new and §3.2 lazy minting. Never reuse local spaceId: local UUIDs are uppercase
    /// (SpaceManager.swift:960), while syncUuid is lowercase, keeping namespace mixups visible in logs/plists.
    func mintSyncUuid(forSpaceId spaceId: String) throws -> String {
        guard spaceId != LocalStore.defaultSpaceId else {
            throw SpaceSyncMappingError.defaultSpaceIsImplicit
        }
        guard store.syncUuid(forSpaceId: spaceId) == nil else {
            throw SpaceSyncMappingError.alreadyMapped
        }
        let uuid = UUID().uuidString.lowercased()
        // Throw on failed persistence before returning the UUID (§2.5 item 2). Publishing it without a durable
        // mapping would mint a duplicate account Space after restart.
        guard store.setSyncUuid(uuid, forSpaceId: spaceId) else {
            throw SpaceSyncMappingError.persistFailed
        }
        return uuid
    }

    /// Wizard mapping to an existing account Space. Guard both reserved namespaces first (R-M3-4a-6): local
    /// uppercase spaceId cannot substitute for checking account UUIDs. Then reject default Space, existing
    /// mapping and a UUID claimed by another local Space.
    func map(spaceId: String, toSyncUuid uuid: String) throws {
        guard !SpaceManager.isIncognitoSpaceId(spaceId) else {
            throw SpaceSyncMappingError.reservedSpaceId
        }
        guard uuid != SyncableSpaces.defaultSpaceUuid,
              uuid != SyncableSpaces.incognitoSpaceUuid else {
            throw SpaceSyncMappingError.reservedSyncUuid
        }
        guard spaceId != LocalStore.defaultSpaceId else {
            throw SpaceSyncMappingError.defaultSpaceIsImplicit
        }
        guard store.syncUuid(forSpaceId: spaceId) == nil else {
            throw SpaceSyncMappingError.alreadyMapped
        }
        guard !store.allMappings().values.contains(uuid) else {
            throw SpaceSyncMappingError.syncUuidAlreadyClaimed
        }
        // After the existing three gates, apply the same persistence guard as mintSyncUuid.
        guard store.setSyncUuid(uuid, forSpaceId: spaceId) else {
            throw SpaceSyncMappingError.persistFailed
        }
    }

    /// Called once per eligible Space before the first snapshot for R-D6-7 lazy minting.
    @discardableResult
    func ensureMapped(spaceId: String) throws -> String {
        if let uuid = syncUuid(forSpaceId: spaceId) { return uuid }
        return try mintSyncUuid(forSpaceId: spaceId)
    }

    /// Default Space is a no-op because it has no stored mapping.
    func removeMapping(forSpaceId spaceId: String) {
        store.removeMapping(forSpaceId: spaceId)
    }

    func removeAllMappings() {
        store.removeAllMappings()
    }

    func allMappings() -> [String: String] {
        store.allMappings()
    }
}

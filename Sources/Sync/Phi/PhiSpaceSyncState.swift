// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

extension Notification.Name {
    /// Posted whenever the engine pushes a new hidden / unsynced set back to
    /// `PhiSpaceSyncState.shared`. `SpaceManager` re-runs `handleSpacesUpdate`
    /// on its UNFILTERED `lastStoreSpaces` snapshot when it arrives, so
    /// unhiding needs no SwiftData write at all (§6.6).
    static let phiSpaceHiddenSetDidChange = Notification.Name("phiSpaceHiddenSetDidChange")
}

/// Per-Space sync shadow. One of these per `space_uuid`; the whole table lives
/// in the account plist under `sync.phiSpaces`, so it is account-isolated by
/// construction and needs no entry in `PhiSyncEngine.stateKeys`.
struct PhiSpaceCursor: Codable, Equatable {
    var entityId: String?
    var version: Int64 = 0
    /// Serialized `Phi_PhiSpaceEntity`: the change-detection baseline
    /// (the Space-side analogue of M3-1's `<key>.phiSyncVal` + `.phiSyncTs`).
    var reconciled: Data?
    /// Serialized `Phi_PhiSpaceEntity`: what the SERVER holds (M3-1's
    /// `storedLastEntity`), which is what suppresses a redundant push. Never
    /// the merge result -- see §6.2's five baseline write points.
    var server: Data?
    /// A decrypted entity parked while the D2 question is open, or while its
    /// `profile_uuid` still resolves to no local profile (§3.5 fallback B).
    var pendingApply: Data?
    /// Remote binding on an ALREADY-LANDED Space that resolves to no local
    /// profile (§3.5 fallback A). Echoed back with `reconciled`'s own
    /// timestamp, never stamped `now`.
    var heldProfileUuid: String?
    /// The LOCAL profile the hold above was taken against. §3.5: "本机之后主动
    /// 换绑该 Space 时清掉它并按普通字段盖 `now`" -- without this the snapshot
    /// cannot tell "the user has since rebound this Space locally" from "nothing
    /// changed", because the `reconciled` baseline records the REMOTE value and
    /// the local side has no baseline of its own. When this no longer equals the
    /// row's `profileId`, the hold is stale and the local binding is published
    /// normally.
    var heldForLocalProfileId: String?
    var pendingDelete = false
    /// Consecutive INVALID_MESSAGE rejections of this tombstone (§5.1).
    var deleteRejectRounds = 0
    /// A remote tombstone identified by hash but not landed yet (import lock).
    var pendingTombstone = false
    var deletedAtMs: Int64?
    /// Not in the strip: D2 "account wins", or a soft delete.
    var hidden = false
    /// Agent / incognito / excluded: recorded so it is not decrypted and
    /// refused again every round. Such a cursor has NO `entityId`, which is
    /// what makes §9.1's delete-origin criterion safe.
    var refusedAtMs: Int64?
    /// The 30-day sweep ran: baselines dropped, the cursor itself kept forever
    /// as a tombstone record (§9.2).
    var purgedAtMs: Int64?
}

struct PhiSpaceSyncTable: Codable, Equatable {
    var cursors: [String: PhiSpaceCursor] = [:]
    /// "keepBoth" | "accountWins" | nil = still pending (§8).
    var firstSyncDecision: String?
    var drainInProgress = false
    var hasDrainedFullReplay = false
    var hadRecords = false
    var spaceSectionEnabled = false
    var markerMovedWhileGateShut = false
    var didReplayForEmptyTable = false
    var lastDrainedBirthday: String?
    /// `client_tag_hash` -> lastSeenAtMs. Rows the server holds under data type
    /// 2000 that this device pulled but could not turn into a Space. Keyed by
    /// hash because a failed decrypt yields no `space_uuid`. Guard 3 refuses to
    /// commit any entry whose tag hash is in here (§5.5).
    var unreadableTagHashes: [String: Int64] = [:]

    // MARK: - Derived sets

    /// Both kinds of hidden: D2's "account wins" and remote soft deletes.
    /// Drives §6.6's funnel filter and §9.4's over-conservative reference check.
    var hiddenSpaceIds: Set<String> {
        Set(cursors.filter { $0.value.hidden }.keys)
    }

    /// ONLY the D2 kind (§8.3): a soft-deleted Space is hidden too, but it is
    /// not "a Space that only exists on this Mac", "join account sync" is a dud
    /// for it, and the 30-day sweep would cascade it away days later.
    var unsyncedSpaceIds: Set<String> {
        Set(cursors.filter { $0.value.hidden && $0.value.deletedAtMs == nil }.keys)
    }

    // MARK: - Mutations (the engine runs these on its round queue; the facade
    // runs the same code directly only when no engine exists -- §5.3)

    /// §9.1: mark ONLY a uuid that has actually been published to the account
    /// and still belongs to it. The criterion is `entityId`, NOT "the table has
    /// a cursor": agent / incognito entities refused by §6.5 own a cursor with
    /// only `refusedAtMs`, D2-hidden Spaces own one with only `hidden`.
    /// Returns whether anything changed.
    @discardableResult
    mutating func recordLocalDeletion(spaceId: String) -> Bool {
        guard var cursor = cursors[spaceId],
              cursor.entityId != nil,
              cursor.deletedAtMs == nil,
              cursor.hidden == false,
              cursor.pendingDelete == false else { return false }
        cursor.pendingDelete = true
        cursors[spaceId] = cursor
        return true
    }

    /// §8.3's second gate: a soft-deleted Space must never be put back in the
    /// strip, and a uuid that is already in the account never belonged in the
    /// "not synced to the account" section in the first place.
    @discardableResult
    mutating func joinAccountSync(spaceId: String) -> Bool {
        guard var cursor = cursors[spaceId], cursor.hidden,
              cursor.deletedAtMs == nil, cursor.entityId == nil else { return false }
        cursor.hidden = false
        cursors[spaceId] = cursor
        return true
    }

    /// Soft deletes older than the retention window: returns the uuids whose
    /// local data the caller must now cascade away, and trims their cursors to
    /// permanent tombstones (§9.2 -- the cursor itself is never dropped).
    mutating func purgeExpired(nowMs: Int64) -> [String] {
        var purged: [String] = []
        for (uuid, cursor) in cursors {
            guard let deletedAtMs = cursor.deletedAtMs, cursor.purgedAtMs == nil,
                  nowMs - deletedAtMs > PhiSpaceSyncState.retentionMs else { continue }
            var tombstone = PhiSpaceCursor()
            tombstone.entityId = cursor.entityId
            tombstone.version = cursor.version
            tombstone.hidden = true
            tombstone.deletedAtMs = deletedAtMs
            tombstone.purgedAtMs = nowMs
            cursors[uuid] = tombstone
            purged.append(uuid)
        }
        return purged.sorted()
    }

    /// §9.4 criteria 1 and 2, as ONE implementation (R4): every global profile
    /// uuid an account Space (from either baseline) or a held binding still
    /// points at. Soft-deleted and purged cursors do not count.
    ///
    /// `PhiSpaceSyncState.refreshCaches` builds its `referencedProfileUuids`
    /// cache from this and nothing else. A second copy of the predicate --
    /// deserialize both baselines, compare `profileUuid.stringValue`, skip the
    /// soft-deleted -- is exactly the drift R4 rejects for `lwwWinner` /
    /// `signature`: the two would eventually disagree about whether a Profile is
    /// deletable, in opposite directions on the two call sites.
    func referencedProfileUuids() -> Set<String> {
        var referenced: Set<String> = []
        for cursor in cursors.values where cursor.deletedAtMs == nil {
            if let held = cursor.heldProfileUuid, !held.isEmpty { referenced.insert(held) }
            for bytes in [cursor.server, cursor.reconciled].compactMap({ $0 }) {
                guard let entity = try? Phi_PhiSpaceEntity(serializedBytes: bytes) else { continue }
                let uuid = entity.profileUuid.stringValue
                if !uuid.isEmpty { referenced.insert(uuid) }
            }
        }
        return referenced
    }

    func referencesProfileUuid(_ uuid: String) -> Bool {
        referencedProfileUuids().contains(uuid)
    }
}

protocol PhiSpaceSyncStateStore: AnyObject {
    func load() -> PhiSpaceSyncTable
    func save(_ table: PhiSpaceSyncTable)
}

/// The table in the account plist, next to `sync.profileGlobalUuids`.
/// `AccountUserDefaults` writes `users/<userID>/defaults/account_defaults.plist`,
/// so the table is account-scoped for free.
final class AccountPhiSpaceSyncStateStore: PhiSpaceSyncStateStore {
    static let defaultsKey = "sync.phiSpaces"
    private let defaults: AccountUserDefaults

    init(defaults: AccountUserDefaults) { self.defaults = defaults }

    func load() -> PhiSpaceSyncTable {
        defaults.codableValue(forKey: Self.defaultsKey) ?? PhiSpaceSyncTable()
    }

    func save(_ table: PhiSpaceSyncTable) {
        defaults.set(table, forCodableKey: Self.defaultsKey)
    }
}

/// Main-thread face of the table for `SpaceManager` and the settings UI.
///
/// SINGLE WRITER (§5.3): the table is owned by the engine actor. Everything
/// here is either a READ-ONLY cache the engine pushes back, or an INTENT the
/// engine executes on its serial round queue. The one exception is "there is no
/// engine" (signed out, ARK locked, `stopPhiSync()` done), where nobody else can
/// be writing and the facade may touch the store directly.
@MainActor
final class PhiSpaceSyncState {
    static let shared = PhiSpaceSyncState()

    /// `nonisolated` because `PhiSpaceSyncTable.purgeExpired(nowMs:)` -- a
    /// nonisolated mutating func on a struct the engine owns off the main actor
    /// -- reads it. Without it this is a Swift 6 hard error and a Swift 5
    /// warning at every such read.
    nonisolated static let retentionMs: Int64 = 30 * 24 * 60 * 60 * 1000

    enum Intent {
        case recordLocalDeletion(String)
        case joinAccountSync(String)
        case runRetentionSweep
    }

    /// Set by `PhiChromiumCoordinator` while an engine exists; nil means the
    /// direct-store fallback applies.
    var intentSink: ((Intent) -> Void)?
    /// Used only on the no-engine path.
    var directStore: PhiSpaceSyncStateStore?
    /// localProfileId -> account-global uuid (`ProfileKeyManager` mapping).
    var globalUuidLookup: ((String) -> String?)?
    /// Every LOCAL Space row with its profile, unfiltered by §6.6's funnel --
    /// `account.localStorage.getAllSpaces()` in production. Needed for §9.4's
    /// third criterion (hidden local Spaces have no cursor `profile_uuid`).
    var localSpaceProfileIds: (() -> [(spaceId: String, profileId: String)])?

    private(set) var hiddenSpaceIds: Set<String> = []
    private(set) var unsyncedSpaceIds: Set<String> = []
    private(set) var hasDrainedFullReplay = false
    private var referencedProfileUuids: Set<String> = []

    func isHidden(_ spaceId: String) -> Bool { hiddenSpaceIds.contains(spaceId) }

    /// Called by the engine after every table write, and by the fallback path.
    func refreshCaches(from table: PhiSpaceSyncTable) {
        let hidden = table.hiddenSpaceIds
        let unsynced = table.unsyncedSpaceIds
        // One implementation of the reference rule, on the table (R4).
        let referenced = table.referencedProfileUuids()
        let changed = hidden != hiddenSpaceIds || unsynced != unsyncedSpaceIds
        hiddenSpaceIds = hidden
        unsyncedSpaceIds = unsynced
        referencedProfileUuids = referenced
        hasDrainedFullReplay = table.hasDrainedFullReplay
        if changed {
            NotificationCenter.default.post(name: .phiSpaceHiddenSetDidChange, object: self)
        }
    }

    func recordLocalDeletion(spaceId: String) { deliver(.recordLocalDeletion(spaceId)) }
    func joinAccountSync(spaceId: String) { deliver(.joinAccountSync(spaceId)) }
    func runRetentionSweep() { deliver(.runRetentionSweep) }

    /// §9.4: "a Profile still referenced by a Space cannot be deleted", widened
    /// from `SpaceManager.spaces` to the account. Fail-OPEN before the first
    /// full drain: a long-offline / long-locked machine must not be stuck with
    /// a prompt that never clears (the caller shows the warning instead).
    func blocksProfileDeletion(localProfileId: String) -> Bool {
        guard hasDrainedFullReplay else { return false }
        if let uuid = globalUuidLookup?(localProfileId), referencedProfileUuids.contains(uuid) {
            return true
        }
        // Hidden local Spaces: filtered out of `spaceManager.spaces` by §6.6 and
        // never published, so neither of the two checks above can see them.
        let rows = localSpaceProfileIds?() ?? []
        return rows.contains { hiddenSpaceIds.contains($0.spaceId) && $0.profileId == localProfileId }
    }

    private func deliver(_ intent: Intent) {
        if let intentSink {
            intentSink(intent)
            return
        }
        guard let directStore else { return }
        var table = directStore.load()
        switch intent {
        case .recordLocalDeletion(let spaceId): table.recordLocalDeletion(spaceId: spaceId)
        case .joinAccountSync(let spaceId): table.joinAccountSync(spaceId: spaceId)
        case .runRetentionSweep:
            // Data cascade needs SpaceManager, which the no-engine path has no
            // business driving; the sweep runs for real at the next engine start.
            return
        }
        directStore.save(table)
        refreshCaches(from: table)
    }
}

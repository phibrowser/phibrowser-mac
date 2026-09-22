// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

extension Notification.Name {
    /// Posted whenever the engine pushes a new hidden set back to
    /// `PhiSpaceSyncState.shared`. `SpaceManager` re-runs `handleSpacesUpdate`
    /// on its UNFILTERED `lastStoreSpaces` snapshot when it arrives, so a row
    /// that leaves the hidden set needs no SwiftData write at all (§6.6).
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
    /// A decrypted entity parked while its `profile_uuid` still resolves to no
    /// local profile (§3.5 fallback B).
    var pendingApply: Data?
    /// Serialized `Phi_PhiSpaceEntity`: this device's own OUTBOUND projection of the Space, with
    /// every changed field already stamped at the time the user changed it (C2-a, design option
    /// S2). The outbound mirror of `pendingApply`.
    ///
    /// `SpaceModel` has no edit-date column, and `theme_id`, the overlay opacities and the Profile
    /// binding are not even on the row -- they are joined in from `AccountUserDefaults` at the sync
    /// boundary -- so there is nowhere to read a per-field edit time back from. The engine's
    /// stamping pass therefore records one here, before the pull gate, and `SyncableSpaces.snapshot`
    /// reads it back as the effective baseline: a field whose bytes still match this projection
    /// keeps the stamp it was given, so a second offline edit of another field leaves the first
    /// field's edit time alone. Written only for a cursor that already has a `reconciled` baseline,
    /// and cleared whenever that baseline moves (a landing, an accepted commit, a tombstone).
    ///
    /// Optional, like `pendingApply`: synthesized decoding reads an optional with
    /// `decodeIfPresent`, so a table written by a build without this field still decodes -- the
    /// compatibility rule `PhiOwnedItemCursor.rekeyRejectRounds` states for its own addition. An
    /// older build simply ignores the key and stamps at publish time as it always did; no
    /// `formatVersion` change, no migration and nothing on the wire.
    var pendingProjection: Data?
    /// Remote binding on an ALREADY-LANDED Space that resolves to no local
    /// profile (§3.5 fallback A). Echoed back with `reconciled`'s own
    /// timestamp, never stamped `now`.
    var heldProfileUuid: String?
    /// Local Profile against which the hold was taken (§3.5). When the user rebinds this Space, clear the hold
    /// and stamp the local binding normally with now. reconciled contains the remote value, so this field is
    /// necessary to distinguish a subsequent local rebind from no change. A mismatch with current profileId
    /// makes the hold stale.
    var heldForLocalProfileId: String?
    var pendingDelete = false
    /// Consecutive INVALID_MESSAGE rejections of this tombstone (§5.1).
    var deleteRejectRounds = 0
    /// A remote tombstone identified by hash but not landed yet (import lock).
    var pendingTombstone = false
    var deletedAtMs: Int64?
    /// Remote soft deletion (§9.2), the sole hidden meaning after D6. Invariant: hidden implies nonnil
    /// deletedAtMs, pinned by Task 2 tests.
    var hidden = false
    /// Agent / incognito / excluded: recorded so it is not decrypted and
    /// refused again every round. Such a cursor has NO `entityId`, which is
    /// what makes §9.1's delete-origin criterion safe.
    var refusedAtMs: Int64?
    /// The 30-day sweep ran: baselines dropped, the cursor itself kept forever
    /// as a tombstone record (§9.2).
    var purgedAtMs: Int64?
}

/// One cursor per account syncUuid, never local spaceId (M3-2b §3.1 / R-D6-8). Cursors can exist without rows
/// (refused entities or retained tombstones); tag hashes derive from syncUuid for tombstone identity
/// resolution; and resurrection guards must survive mapping deletion. Persist in account-scoped sync.phiSpaces
/// plist, outside PhiSyncEngine.stateKeys.
struct PhiSpaceSyncTable: Codable, Equatable {
    /// M3-2 was unreleased: discard lower-version tables without migration (§3.6).
    static let currentFormatVersion = 2
    var formatVersion: Int = currentFormatVersion
    /// Keyed by account syncUuid.
    var cursors: [String: PhiSpaceCursor] = [:]

    // MARK: - Shared marker-derived state (one copy across kinds)
    //
    // These fields describe this device's relation to the shared marker, not only Spaces. One datatype/marker
    // has one drain state across settings, Spaces, bookmarks, pins and future kinds. Never duplicate it in
    // per-kind PhiOwnedItemTable files (§3.5).
    //
    // There are 12 fields: spec §3.5's eleven marker-derived values plus spaceSectionEnabled, a persisted gate
    // value. CASE 3.12 in PhiOwnedItemStateTests pins their names; review this contract before adding more.
    //
    // New fields must use decodeIfPresent with defaults in explicit init(from:). Synthesized decoding ignores
    // property defaults for missing nonoptional keys, invalidating older tables and potentially sending users
    // back to pairing. Unchanged formatVersion does not prevent this.
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

    /// Whether this device ever persisted a nonempty entityId cursor for each kind (§3.5 / N2 / R-M3-3-13).
    /// Set once and never clear. Store these outside the per-kind file whose loss they detect, as part of
    /// shared-marker state. They distinguish missing/invalid/old/empty cursor files from never-published
    /// kinds.
    ///
    /// Do not infer this from local syncId rows: pins have no such column, hiding loss and permitting
    /// version-0 blind overwrites. URL Rules always have syncId after insertion (R-M3-4a-23), so that
    /// inference would force full replay every round even before publication (spec §10).
    var bookmarksHadRecords = false
    var pinsHadRecords = false
    var urlRulesHadRecords = false

    /// Independent per-kind one-time replay gates (A2), never reuse permanent didReplayForEmptyTable, which
    /// resets only for a new store birthday. Otherwise Space could consume the only replay and leave
    /// bookmark/pin loss unrecoverable.
    ///
    /// These gates rearm when a published cursor is restored: file-loss recovery has a clear edge, unlike the
    /// Space empty-table condition. Reporting loss itself closes publication by dropping the marker, rearming
    /// drainInProgress and clearing hasDrainedFullReplay; no second flag is needed (M2). URL Rules have their
    /// own independent gate, never inferred from always-present local syncId rows (R-M3-4a-23).
    var bookmarksReplayedForEmptyTable = false
    var pinsReplayedForEmptyTable = false
    var urlRulesReplayedForEmptyTable = false

    // MARK: - Derived sets

    /// All hidden cursor syncUuids. After D6, hidden means remote soft deletion and implies deletedAtMs.
    /// PhiSpaceSyncState.refreshCaches translates to local IDs (§3.5).
    var hiddenSyncUuids: Set<String> {
        Set(cursors.filter { $0.value.hidden }.keys)
    }

    /// syncUuids actually present on the account (entityId != nil), precomputed for blocksProfileDeletion's
    /// third predicate (§3.5), whose main-actor caller does not own the table.
    var publishedSyncUuids: Set<String> {
        Set(cursors.filter { $0.value.entityId != nil }.keys)
    }

    // MARK: - Mutations (the engine runs these on its round queue; the facade
    // runs the same code directly only when no engine exists -- §5.3)

    /// §9.1: mark only UUIDs actually published and still on the account, using entityId rather than mere
    /// cursor presence; refused agent/incognito cursors may contain only refusedAtMs. Return whether state
    /// changed.
    ///
    /// D6: despite the parameter name, this takes syncUuid. Both engine recordLocalDeletion and fallback
    /// PhiSpaceSyncState.deliver translate local IDs before calling; unmapped means never published and
    /// returns early at those boundaries.
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

    /// load version gate: missing/undecodable data and older formats all become an empty table.
    static func loaded(from decoded: PhiSpaceSyncTable?) -> PhiSpaceSyncTable {
        guard let decoded, decoded.formatVersion >= currentFormatVersion else {
            return PhiSpaceSyncTable()
        }
        return decoded
    }

    /// Check raw data, not load output: codableValue merges missing-key and decoding failure into nil, then
    /// load makes both empty. Testing that result would falsely report discard on every first launch. Missing
    /// raw key returns false without writes.
    static func isStaleFormat(rawData: Data?) -> Bool {
        guard let rawData else { return false }
        guard let decoded = try? JSONDecoder().decode(PhiSpaceSyncTable.self, from: rawData) else {
            return true
        }
        return decoded.formatVersion < currentFormatVersion
    }
}

// Define init(from:) in an extension to preserve synthesized PhiSpaceSyncTable(), the repository's empty-table
// initializer. Compiler-synthesized encode/CodingKeys still include new fields; only decoding needs an
// explicit line.
extension PhiSpaceSyncTable {
    /// Backward-compatible decoding only. Synthesized decoding requires nonoptional keys regardless of
    /// defaults, so older format-2 tables missing added flags would decode as nil/empty and falsely appear
    /// stale, overwriting state and reopening pairing. Decode new per-kind flags with decodeIfPresent ??
    /// false, correct for never-published kinds without migration. Keep original format-2 fields required:
    /// missing originals indicate corruption.
    init(from decoder: Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try container.decode(Int.self, forKey: .formatVersion)
        cursors = try container.decode([String: PhiSpaceCursor].self, forKey: .cursors)
        drainInProgress = try container.decode(Bool.self, forKey: .drainInProgress)
        hasDrainedFullReplay = try container.decode(Bool.self, forKey: .hasDrainedFullReplay)
        hadRecords = try container.decode(Bool.self, forKey: .hadRecords)
        spaceSectionEnabled = try container.decode(Bool.self, forKey: .spaceSectionEnabled)
        markerMovedWhileGateShut = try container.decode(Bool.self, forKey: .markerMovedWhileGateShut)
        didReplayForEmptyTable = try container.decode(Bool.self, forKey: .didReplayForEmptyTable)
        lastDrainedBirthday = try container.decodeIfPresent(String.self, forKey: .lastDrainedBirthday)
        unreadableTagHashes = try container.decode([String: Int64].self, forKey: .unreadableTagHashes)
        // Four milestone additions: absent keys mean an older valid table, not corruption.
        bookmarksHadRecords =
            try container.decodeIfPresent(Bool.self, forKey: .bookmarksHadRecords) ?? false
        pinsHadRecords =
            try container.decodeIfPresent(Bool.self, forKey: .pinsHadRecords) ?? false
        bookmarksReplayedForEmptyTable =
            try container.decodeIfPresent(Bool.self, forKey: .bookmarksReplayedForEmptyTable) ?? false
        pinsReplayedForEmptyTable =
            try container.decodeIfPresent(Bool.self, forKey: .pinsReplayedForEmptyTable) ?? false
        // M3-4a adds two URL Rule flags; absent keys likewise mean an older table.
        urlRulesHadRecords =
            try container.decodeIfPresent(Bool.self, forKey: .urlRulesHadRecords) ?? false
        urlRulesReplayedForEmptyTable =
            try container.decodeIfPresent(Bool.self, forKey: .urlRulesReplayedForEmptyTable) ?? false
    }
}

protocol PhiSpaceSyncStateStore: AnyObject {
    func load() -> PhiSpaceSyncTable
    /// False means table persistence failed (R-M3-4a-83), matching per-kind JSON stores. Discardable result
    /// preserves discardIfStaleFormat's existing ignored return.
    @discardableResult func save(_ table: PhiSpaceSyncTable) -> Bool
}

/// The table in the account plist, next to `sync.profileGlobalUuids`.
/// `AccountUserDefaults` writes `users/<userID>/defaults/account_defaults.plist`,
/// so the table is account-scoped for free.
final class AccountPhiSpaceSyncStateStore: PhiSpaceSyncStateStore {
    static let defaultsKey = "sync.phiSpaces"
    private let defaults: AccountUserDefaults

    init(defaults: AccountUserDefaults) { self.defaults = defaults }

    func load() -> PhiSpaceSyncTable {
        PhiSpaceSyncTable.loaded(from: defaults.codableValue(forKey: Self.defaultsKey))
    }

    /// Forward AccountUserDefaults.set's result throughout. Its rollback ensures failed persistence means load
    /// still returns the old table.
    @discardableResult
    func save(_ table: PhiSpaceSyncTable) -> Bool {
        defaults.set(table, forCodableKey: Self.defaultsKey)
    }

    /// True means a stored old table was discarded (§3.6). No key on new/login/always-locked devices returns
    /// false without writes. isStaleFormat owns the predicate; this wrapper only reads, guards and writes.
    @discardableResult
    func discardIfStaleFormat() -> Bool {
        guard PhiSpaceSyncTable.isStaleFormat(rawData: defaults.data(forKey: Self.defaultsKey)) else {
            return false
        }
        save(PhiSpaceSyncTable())
        return true
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
        case runRetentionSweep
    }

    /// Set by `PhiChromiumCoordinator` while an engine exists; nil means the
    /// direct-store fallback applies.
    var intentSink: ((Intent) -> Void)?
    /// Used only on the no-engine path.
    var directStore: PhiSpaceSyncStateStore?
    /// localProfileId -> account-global uuid (`ProfileKeyManager` mapping).
    var globalUuidLookup: ((String) -> String?)?
    /// syncUuid → local spaceId, the sole reverse resolver used by refreshCaches for hiddenSyncUuids (§3.5).
    var localSpaceIdLookup: ((String) -> String?)?
    /// Local spaceId → syncUuid for blocksProfileDeletion's third predicate (§2.2 / §3.5) and deliver's
    /// no-engine fallback before writing the syncUuid-keyed table (§3.4). localSpaceIdLookup goes the opposite
    /// direction and cannot serve either caller.
    var syncUuidLookup: ((String) -> String?)?
    /// Every LOCAL Space row with its profile, unfiltered by §6.6's funnel --
    /// `account.localStorage.getAllSpaces()` in production. Needed for §9.4's
    /// third criterion (hidden local Spaces have no cursor `profile_uuid`).
    var localSpaceProfileIds: (() -> [(spaceId: String, profileId: String)])?

    /// Local Space IDs for SpaceManager.handleSpacesUpdate filtering (SpaceManager.swift:2691-2692),
    /// preserving its existing semantics.
    private(set) var hiddenSpaceIds: Set<String> = []
    /// syncUuids with real account entities (§3.5); excluded from changed comparison.
    private(set) var publishedSyncUuids: Set<String> = []
    private(set) var hasDrainedFullReplay = false
    private var referencedProfileUuids: Set<String> = []

    func isHidden(_ spaceId: String) -> Bool { hiddenSpaceIds.contains(spaceId) }

    /// Called by the engine after every table write, and by the fallback path.
    func refreshCaches(from table: PhiSpaceSyncTable) {
        // Translate table syncUuids to local IDs at this boundary (§3.5). Ignore unresolved hidden/refused
        // cursors with no local rows; they do not belong in the UI filter.
        let hidden = Set(table.hiddenSyncUuids.compactMap { localSpaceIdLookup?($0) })
        // One implementation of the reference rule, on the table (R4).
        let referenced = table.referencedProfileUuids()
        let changed = hidden != hiddenSpaceIds
        hiddenSpaceIds = hidden
        publishedSyncUuids = table.publishedSyncUuids
        referencedProfileUuids = referenced
        hasDrainedFullReplay = table.hasDrainedFullReplay
        if changed {
            NotificationCenter.default.post(name: .phiSpaceHiddenSetDidChange, object: self)
        }
    }

    func recordLocalDeletion(spaceId: String) { deliver(.recordLocalDeletion(spaceId)) }
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
        // Third predicate (R-D6-9): mapped local Spaces whose entities were published. Use publishedSyncUuids
        // precomputed by refreshCaches because this method has no table/cursor view, and forward
        // syncUuidLookup rather than the reverse resolver. Before D6 this checked hidden local Spaces.
        let rows = localSpaceProfileIds?() ?? []
        return rows.contains { row in
            guard row.profileId == localProfileId,
                  let uuid = syncUuidLookup?(row.spaceId) else { return false }
            return publishedSyncUuids.contains(uuid)
        }
    }

    private func deliver(_ intent: Intent) {
        if let intentSink {
            intentSink(intent)
            return
        }
        guard let directStore else { return }
        var table = directStore.load()
        switch intent {
        case .recordLocalDeletion(let spaceId):
            // Translate local ID to the table's syncUuid key, as at the engine boundary (§3.4). Missing
            // resolver/mapping means never published and no tombstone to send.
            guard let uuid = syncUuidLookup?(spaceId) else { return }
            table.recordLocalDeletion(spaceId: uuid)
        case .runRetentionSweep:
            // Data cascade needs SpaceManager, which the no-engine path has no
            // business driving; the sweep runs for real at the next engine start.
            return
        }
        // Match engine writeSpaceTable (R-M3-4a-83): refresh main-thread caches only after persistence
        // succeeds, avoiding display of state that vanishes after restart.
        guard directStore.save(table) else { return }
        refreshCaches(from: table)
    }
}

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
    /// Agent / incognito / excluded payload refused at landing. Keeps the uuid
    /// out of `SyncableSpaces.snapshot`; cleared when a later version of the
    /// entity lands. A cursor created by a refusal has NO `entityId`, which is
    /// what makes §9.1's delete-origin criterion safe.
    var refusedAtMs: Int64?
    /// The 30-day sweep ran: baselines dropped, the cursor itself kept forever
    /// as a tombstone record (§9.2).
    var purgedAtMs: Int64?
}

/// Per-account-Profile sync shadow, keyed by the account profile uuid (a value of
/// `sync.profileGlobalUuids`). Lives in the same account plist table as the Space cursors, so it
/// shares the drain state and the atomic `sync.phiSpaces` write (docs/sync.md, "Profile entity").
/// Every field is optional or defaulted and the table decodes it with `decodeIfPresent`, so a
/// table written by a build without Profile entities still loads.
struct PhiProfileCursor: Codable, Equatable {
    var entityId: String?
    var version: Int64 = 0
    /// Serialized `Phi_PhiProfileEntity`: the change-detection baseline.
    var reconciled: Data?
    /// Serialized `Phi_PhiProfileEntity`: what the server holds; suppresses a redundant push.
    var server: Data?
    /// A decrypted entity whose landing failed (a rename that did not take); retried every round.
    var pendingApply: Data?
    /// Serialized `Phi_PhiProfileEntity`: this device's outbound projection, stamped when the
    /// user renamed the Profile. Same role as `PhiSpaceCursor.pendingProjection`.
    var pendingProjection: Data?
    /// The local display name that corresponds to `reconciled` on THIS device. Local names can
    /// legitimately differ from the account name (auto-create and rename suffix duplicates), so
    /// "the local name changed" is decided against this, never against the account name.
    var localNameAtBaseline: String?
    /// A local deletion whose tombstone has not committed yet.
    var pendingDelete = false
    /// Consecutive INVALID_MESSAGE rejections of that tombstone.
    var deleteRejectRounds = 0
    /// A remote tombstone whose local application is deferred; retried every round.
    var pendingTombstone = false
    /// Consecutive rounds the Chromium deletion for a remote tombstone failed.
    var tombstoneDeferRounds = 0
    /// Wall-clock ms when a remote tombstone was first deferred by a local blocker (a running
    /// agent Space, an import, a bound Space's pending deletion). Optional so older cursors decode.
    var firstDeferredAtMs: Int64?
    /// The account Profile is deleted: a remote tombstone landed or this device's own committed.
    var deletedAtMs: Int64?
    /// This device deleted the Profile before any entity for it reached the account, so no
    /// tombstone was owed. A live entity that arrives later (a peer publishing it first) is not an
    /// undelete: delete beats create, and the entity is tombstoned. Optional so cursors written
    /// without it decode.
    var deletedBeforePublish: Bool?
    /// The retention sweep trimmed the baselines; the cursor itself is kept as the tombstone record.
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
    /// Profile entity cursors, keyed by account profile uuid (docs/sync.md, "Profile entity").
    var profileCursors: [String: PhiProfileCursor] = [:]

    // MARK: - Shared marker-derived state (one copy across kinds)
    //
    // These fields describe this device's relation to the shared marker, not only Spaces. One datatype/marker
    // has one drain state across settings, Spaces, bookmarks, pins and future kinds. Never duplicate it in
    // per-kind PhiOwnedItemTable files (§3.5).
    //
    // This includes the persisted gate and the account enrollment replay acknowledgement.
    // CASE 3.12 in PhiOwnedItemStateTests pins the shared field set; none belongs in a per-kind file.
    //
    // New fields must use decodeIfPresent with defaults in explicit init(from:). Synthesized decoding ignores
    // property defaults for missing nonoptional keys, invalidating older tables and potentially sending users
    // back to pairing. Unchanged formatVersion does not prevent this.
    var drainInProgress = false
    var hasDrainedFullReplay = false
    var hadRecords = false
    var spaceSectionEnabled = false
    var markerMovedWhileGateShut = false
    /// Enrollment replay is acknowledged atomically with the durable replay latch.
    var lastEnrollmentReplayToken: UUID? = nil
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

    /// syncUuids whose retention sweep already ran (`purgedAtMs != nil`). The cursors are permanent, so
    /// this only grows.
    var purgedSyncUuids: Set<String> {
        Set(cursors.filter { $0.value.purgedAtMs != nil }.keys)
    }

    /// syncUuids whose Space is deleted on this device: a local deletion queued (`pendingDelete`) or
    /// finished, or a remote one landed (`deletedAtMs`, kept by the permanent purged cursor). A Space
    /// deletion is terminal -- a soft-deleted uuid is never resurrected -- so the bookmarks and pins
    /// it owns are deleted with it (R-M3-4a-78): owned publication tombstones them and owned landing
    /// discards their inbound payloads instead of parking them forever.
    var deletedSyncUuids: Set<String> {
        Set(cursors.filter {
            $0.value.pendingDelete || $0.value.deletedAtMs != nil || $0.value.purgedAtMs != nil
        }.keys)
    }

    /// The uuids whose local cascade a retention sweep runs, sorted: this sweep's newly `expired` uuids plus
    /// every earlier-`purged` uuid that still has a local mapping. The sweep drops a mapping only after its
    /// purge succeeds, so a purged cursor with a retained mapping marks a cascade that failed or was cut short
    /// by a stop; `purgeExpired` never returns that uuid again, and this is its only retry path.
    static func retentionCascadeUuids(expired: [String], purged: Set<String>,
                                      mapped: Set<String>) -> [String] {
        Set(expired).union(purged.intersection(mapped)).sorted()
    }

    /// syncUuids actually present on the account (entityId != nil), precomputed for blocksProfileDeletion's
    /// third predicate (§3.5), whose main-actor caller does not own the table.
    var publishedSyncUuids: Set<String> {
        Set(cursors.filter { $0.value.entityId != nil }.keys)
    }

    /// Account profile uuids that are deleted, or being deleted, on this device: a local deletion
    /// queued (`pendingDelete`) or a deletion recorded (`deletedAtMs`, kept by the purged cursor).
    var deletedProfileUuids: Set<String> {
        Set(profileCursors.filter {
            $0.value.pendingDelete || $0.value.deletedAtMs != nil || $0.value.purgedAtMs != nil
        }.keys)
    }

    /// Account profile uuids with a live Profile entity on the account: an entity this device landed
    /// or committed and that is not deleted. Local Profile auto-create requires membership here.
    var liveProfileEntityUuids: Set<String> {
        let deleted = deletedProfileUuids
        return Set(profileCursors.filter { $0.value.entityId != nil && !deleted.contains($0.key) }.keys)
    }

    /// The account name of every live Profile entity, from its baseline (the landed account value),
    /// falling back to a parked entity that has not landed yet, and to "" when neither decodes.
    var liveProfileEntityNames: [String: String] {
        var names: [String: String] = [:]
        for uuid in liveProfileEntityUuids {
            let cursor = profileCursors[uuid]
            let entity = (cursor?.reconciled ?? cursor?.pendingApply)
                .flatMap { try? Phi_PhiProfileEntity(serializedBytes: $0) }
            names[uuid] = entity?.name.stringValue ?? ""
        }
        return names
    }

    /// Profile deletions older than the retention window: trims the cursors to permanent tombstone
    /// records and returns their uuids. Same model as `purgeExpired` for Spaces.
    mutating func purgeExpiredProfiles(nowMs: Int64) -> [String] {
        var purged: [String] = []
        for (uuid, cursor) in profileCursors {
            // A tombstone still owed (`pendingDelete`) or a decision still pending stays as is.
            guard let deletedAtMs = cursor.deletedAtMs, cursor.purgedAtMs == nil, !cursor.pendingTombstone,
                  !cursor.pendingDelete,
                  nowMs - deletedAtMs > PhiSpaceSyncState.retentionMs else { continue }
            var tombstone = PhiProfileCursor()
            tombstone.entityId = cursor.entityId
            tombstone.version = cursor.version
            tombstone.deletedAtMs = deletedAtMs
            // Kept so a peer's first publication after the purge is still tombstoned, not resurrected.
            tombstone.deletedBeforePublish = cursor.deletedBeforePublish
            tombstone.purgedAtMs = nowMs
            profileCursors[uuid] = tombstone
            purged.append(uuid)
        }
        return purged.sorted()
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
        lastEnrollmentReplayToken = try container.decodeIfPresent(UUID.self, forKey: .lastEnrollmentReplayToken)
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
        // M3-4b adds the Profile entity cursors; an absent key is a table from before Profile entities.
        profileCursors =
            try container.decodeIfPresent([String: PhiProfileCursor].self, forKey: .profileCursors) ?? [:]
    }
}

/// What the drained account says about its Profile entities, for `SyncKeyController`'s
/// auto-create and mapping pass (docs/sync.md, "Enrollment and setup"). The key registry still
/// lists every Profile ever registered; this view is what says which of them still exist.
struct AccountProfileEntityView: Equatable {
    /// Account profile uuid -> account name, for every live Profile entity.
    var liveNames: [String: String]
    var deletedUuids: Set<String>

    var liveUuids: Set<String> { Set(liveNames.keys) }
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
        /// The local id and the syncUuid `beginLocalDeletion` captured while the mapping still resolved.
        case recordLocalDeletion(spaceId: String, syncUuid: String)
        case runRetentionSweep
        /// A local Profile deletion finished in Chromium; its intent is already in the journal.
        case recordLocalProfileDeletion(syncUuid: String)
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
    /// The account's Profile deletion journal (docs/sync.md, "Profile deletion and rename").
    var profileDeletionIntentStore: (any PhiProfileDeletionIntentStore)?
    /// `SyncKeyController`'s per-Profile key withdrawal, restore and its end after a completed
    /// deletion. Closures so `ProfileManager` reaches the key layer only through this facade.
    var withdrawProfileKey: ((String) -> Void)?
    var restoreProfileKey: ((String) -> Void)?
    var finishProfileKeyWithdrawal: ((String) -> Void)?
    /// Called when the set of live or deleted Profile entities changes, so the mapping pass reruns
    /// against it: a Profile deleted here stops counting as an unclaimed account Profile only once
    /// the engine has recorded the deletion.
    var profileEntityViewDidChange: (() -> Void)?

    /// Local Space IDs for SpaceManager.handleSpacesUpdate filtering (SpaceManager.swift:2691-2692),
    /// preserving its existing semantics.
    private(set) var hiddenSpaceIds: Set<String> = []
    /// syncUuids with real account entities (§3.5); excluded from changed comparison.
    private(set) var publishedSyncUuids: Set<String> = []
    private(set) var hasDrainedFullReplay = false
    /// nil until the first full replay of the data type has drained: before that, the absence of a
    /// Profile entity proves nothing.
    private(set) var accountProfileEntityView: AccountProfileEntityView?
    private var referencedProfileUuids: Set<String> = []
    /// syncUuids whose local deletion has started and is not yet recorded in the table (§9.2: delete beats
    /// a concurrent edit). In memory only: the apply loop must not re-land them while the cascade and the
    /// queued deletion round are in flight; from the round on, the cursor's `pendingDelete` protects them.
    private var locallyDeletingSyncUuids: Set<String> = []
    /// Account profile uuids whose Chromium deletion is in flight. In memory only: the journal is
    /// the durable record, and this mark only stops the engine from reading a Profile that is still
    /// present as "the deletion never happened" while Chromium is still deleting it.
    private var locallyDeletingProfileUuids: Set<String> = []

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
        let previousView = accountProfileEntityView
        accountProfileEntityView = table.hasDrainedFullReplay
            ? AccountProfileEntityView(liveNames: table.liveProfileEntityNames,
                                       deletedUuids: table.deletedProfileUuids)
            : nil
        // Not when the view goes away (a reset or a restarted replay): with no view nothing is
        // claimable, and a pass then would register every unmapped local Profile as new.
        if let view = accountProfileEntityView,
           previousView?.liveUuids != view.liveUuids || previousView?.deletedUuids != view.deletedUuids {
            profileEntityViewDidChange?()
        }
        if changed {
            NotificationCenter.default.post(name: .phiSpaceHiddenSetDidChange, object: self)
        }
    }

    /// §9.1 hook, first half: captures the Space's syncUuid before its cascade removes the row and marks it
    /// as being deleted. nil for an unmapped Space (an agent Space), for which the deletion is a no-op.
    func beginLocalDeletion(spaceId: String) -> String? {
        guard let uuid = syncUuidLookup?(spaceId) else { return nil }
        locallyDeletingSyncUuids.insert(uuid)
        return uuid
    }

    /// Second half, only after the cascade committed. The mark is ended once the intent has run.
    func recordLocalDeletion(spaceId: String, syncUuid: String) {
        deliver(.recordLocalDeletion(spaceId: spaceId, syncUuid: syncUuid))
    }

    /// Ends the mark: the cascade failed, or the deletion intent has run.
    func endLocalDeletion(syncUuid: String) { locallyDeletingSyncUuids.remove(syncUuid) }

    func isBeingDeletedLocally(syncUuid: String) -> Bool { locallyDeletingSyncUuids.contains(syncUuid) }

    func runRetentionSweep() { deliver(.runRetentionSweep) }

    // MARK: - Local Profile deletion (docs/sync.md, "Profile deletion and rename")

    /// First step of a user's Profile deletion, before Chromium deletes anything: resolves the
    /// account uuid, persists the intent in the journal and withdraws the Profile's sync key.
    /// nil for an unmapped Profile, which has nothing to propagate. Throws when the intent could
    /// not be saved; the caller must then not delete.
    func beginLocalProfileDeletion(localProfileId: String) throws -> String? {
        guard let uuid = globalUuidLookup?(localProfileId) else { return nil }
        guard let store = profileDeletionIntentStore else { throw PhiProfileDeletionError.intentNotSaved }
        var intents = store.load()
        intents[uuid] = localProfileId
        guard store.save(intents) else { throw PhiProfileDeletionError.intentNotSaved }
        locallyDeletingProfileUuids.insert(uuid)
        withdrawProfileKey?(localProfileId)
        return uuid
    }

    /// The Chromium deletion failed: forget the intent and give the Profile its key back.
    func cancelLocalProfileDeletion(syncUuid: String, localProfileId: String) {
        locallyDeletingProfileUuids.remove(syncUuid)
        removeProfileDeletionIntent(syncUuid: syncUuid)
        restoreProfileKey?(localProfileId)
    }

    /// The Chromium deletion committed. The journal entry stays until the tombstone commits; the
    /// engine round records the deletion on the cursor. With no engine the journal alone carries
    /// it to the next engine start.
    func recordLocalProfileDeletion(syncUuid: String, localProfileId: String) {
        locallyDeletingProfileUuids.remove(syncUuid)
        finishProfileKeyWithdrawal?(localProfileId)
        deliver(.recordLocalProfileDeletion(syncUuid: syncUuid))
    }

    func profileDeletionIntents() -> [String: String] { profileDeletionIntentStore?.load() ?? [:] }

    func isProfileBeingDeletedLocally(syncUuid: String) -> Bool {
        locallyDeletingProfileUuids.contains(syncUuid)
    }

    /// Removes one journal entry: its tombstone committed, or no tombstone is owed.
    func removeProfileDeletionIntent(syncUuid: String) {
        guard let store = profileDeletionIntentStore else { return }
        var intents = store.load()
        guard intents.removeValue(forKey: syncUuid) != nil else { return }
        store.save(intents)
    }

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
            guard row.profileId == localProfileId, !isHidden(row.spaceId),
                  let uuid = syncUuidLookup?(row.spaceId) else { return false }
            return publishedSyncUuids.contains(uuid)
        }
    }

    /// Whether a local Space row keeps this Profile from being deleted locally: any row bound to it
    /// except one a remote deletion soft-deleted (hidden), which is only kept for the retention
    /// window and purged with its Space. The same rule the follower applies to a remote Profile
    /// tombstone (`profileDeletionBlockers`). `SpaceManager.isProfileInUse` answers through this.
    /// The local Space ids among `spaceIds` that a remote deletion soft-deleted. Reads the stored
    /// table as well as the cache, so an answer taken before the engine first refreshed the cache
    /// is not an empty set.
    func remotelyDeletedSpaceIds(among spaceIds: [String]) -> Set<String> {
        let stored = directStore?.load().hiddenSyncUuids ?? []
        return Set(spaceIds.filter { spaceId in
            isHidden(spaceId) || syncUuidLookup?(spaceId).map { stored.contains($0) } == true
        })
    }

    func hasLiveSpaceRow(localProfileId: String, rows: [(spaceId: String, profileId: String)]) -> Bool {
        rows.contains { $0.profileId == localProfileId && !isHidden($0.spaceId) }
    }

    private func deliver(_ intent: Intent) {
        if let intentSink {
            intentSink(intent)
            return
        }
        // No engine: the write below is synchronous, so the deletion is recorded (or lost) on return.
        defer {
            if case .recordLocalDeletion(_, let syncUuid) = intent { endLocalDeletion(syncUuid: syncUuid) }
        }
        // The journal already holds a Profile deletion; the next engine round records it.
        if case .recordLocalProfileDeletion = intent { return }
        guard let directStore else { return }
        var table = directStore.load()
        switch intent {
        case .recordLocalDeletion(_, let syncUuid):
            // The syncUuid was captured before the cascade removed the row (§3.4); the mapping is not
            // read again here.
            table.recordLocalDeletion(spaceId: syncUuid)
        case .runRetentionSweep, .recordLocalProfileDeletion:
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

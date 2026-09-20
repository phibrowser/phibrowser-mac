// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

// Owned-item sync state: one table/file per kind (§3.5), under account.userDataStorage/sync as
// bookmarks-cursors.json, pins-cursors.json and urlrules-cursors.json (M3-4a). All three share
// PhiOwnedItemTable/PhiOwnedItemCursor unchanged; rule merge partners belong in V11 mergePartnerSyncId, never
// cursor fields (RR8-4 / §4.4).
//
// The directory is App Support/Phi/users/<userID>, beside localDB/defaults, so account switches/resets need no
// cleanup or PhiSyncEngine.stateKeys entries (§9.2). Do not place these tables in the account plist: thousands
// of cursors with up to three entity copies would force whole-preference rewrites on every small change.
//
// Single-writer discipline matches M3-2 §5.3: every writer must be a Round in engine roundQueue. Actor
// isolation alone is insufficient because actors reenter. Persist complete tables with atomic Data.write.

/// Entire cursor table for one kind, with a separate file and independently evolving formatVersion.
struct PhiOwnedItemTable: Codable, Equatable {
    /// Version 1 is M3-3's initial format. Discard older/undecodable tables without migration, like M3-2b
    /// §3.6. Report loss through load(hadRecords:) so the engine performs §3.5 full-type replay.
    static let currentFormatVersion = 1
    var formatVersion: Int = currentFormatVersion
    /// Keys are kind identities: bookmark_uuid or pin lineage:ownerKey. No first-merge-window state is
    /// permitted (R-M3-3-22 / R-M3-3-28): no firstArrival, claimEligible, lastArrivalMs, local-mint flags or
    /// deduplication remnants. §6 claiming is stateless, continuous and never deletes; extra state must not
    /// enable deletion merely because rows look duplicated.
    var cursors: [String: PhiOwnedItemCursor] = [:]

    /// Drop whole tombstone cursors 30 days after finalized deletion (§3.6), during retentionSweep. Reuse
    /// PhiSpaceSyncState.retentionMs, matching M1 §2 recovery, to prevent drifting retention constants.
    ///
    /// Unlike Space cursors, dropping is safe: GetUpdates returns only the latest row per entity_id with
    /// version > marker, never pre-deletion history. Redelivery is either the current tombstone or a newer
    /// resurrection (R-M3-3-23). Without a cursor, tombstones follow T1 without creating state, while
    /// resurrection lands as a create; both are correct. Do not restore the obsolete proof that redelivery is
    /// always a tombstone, which would incorrectly forbid resurrection. Space cursors also support local
    /// hidden-state UI and purge, so retain them; owned items have no such soft-delete role.
    mutating func dropExpiredTombstones(nowMs: Int64) {
        cursors = cursors.filter { _, cursor in
            guard let deletedAtMs = cursor.deletedAtMs else { return true }
            return nowMs - deletedAtMs <= PhiSpaceSyncState.retentionMs
        }
    }
}

extension PhiOwnedItemTable {
    /// After §8.4.2 step 4 claiming, remove the entire old locally minted cursor (R-M3-4a-53). Like
    /// dropExpiredTombstones, centralize whole-identity removal on PhiOwnedItemTable to document when deletion
    /// is allowed. Add no cursor fields (RR8-4). Absent identities are idempotent no-ops; never substitute an
    /// empty cursor, which R-exec-13 key repair and §4.2 3b would repeatedly scan (CASE M-31).
    mutating func removeCursor(identity: String) { cursors.removeValue(forKey: identity) }
}

/// Sync state for one owned identity. Keep each field's rationale documented. Compared with PhiSpaceCursor,
/// omit hidden/purgedAtMs because remote deletion hard-deletes local rows and server retention supplies
/// recovery. Omit refusedAtMs: §4.6 structural errors must be reconsidered each round so repaired peers can
/// recover, unlike permanently remembered refusal. Also omit heldProfileUuid/heldForLocalProfileId: Space
/// fallback can land while retaining an unresolved binding, but owned-item owner is part of location, so
/// unresolved ownership must park before landing.
struct PhiOwnedItemCursor: Codable, Equatable {
    /// Server entity ID; empty means never present on the account and next publication is create. Also
    /// determines the per-kind had-published-records flag (§3.5).
    var entityId: String = ""
    /// Server entity version, used as commit baseVersion.
    var version: Int64 = 0
    /// Serialized change-detection baseline, analogous to M3-1 key.phiSyncVal.
    var reconciled: Data?
    /// Serialized entity actually held by the server, used to suppress redundant publication. Never the merge
    /// result.
    var server: Data?
    /// Current resolved local owner: containing Space syncUuid for bookmarks, ownerKey for pins. Never blindly
    /// copy wire space_uuid (A12): descendant diagnostics retain the pre-move Space forever under R-M3-3-18.
    /// Derive from the parent chain during landing and local row during snapshot.
    ///
    /// Every snapshot pre-pass refreshes all cursors with corresponding local rows, including identities
    /// outside the 250-row slice, from the full allBookmarks/allPins read (R-exec-8 / N3 / I9). Retain the
    /// last owner when no local row exists: diff needs it for §4.7 tombstones, and nil would make its
    /// conservative guard skip deletion forever.
    ///
    /// This supports §9.3 retention cascade, §4.2 hidden-Space exclusion and parked diagnostics without
    /// decoding every baseline. It can still lag while gates/drain/scope mismatch block push, so cascade must
    /// additionally ensure no live local row claims the identity.
    var ownerUuid: String?
    /// Inbound entity parked until its bookmark Space/parent or pin owner lands.
    var pendingApply: Data?
    /// Unresolved owner UUID for §11 parked diagnostics and §4.4 unpark checks.
    var pendingOwnerUuid: String?
    /// Remote tombstone recognized by hash but not landed due to import lock. It has no ciphertext for
    /// pendingApply, and the shared marker already passed its page, so retain it explicitly like
    /// PhiSpaceCursor.pendingTombstone.
    var pendingTombstone: Bool = false
    /// Half-landed split pair (§7.4): this row exists but the partner lineage does not. While nonnil, snapshot
    /// copies baseline split_partner_uuid; publishing empty would split the remote pair too.
    var pendingPartnerLineage: String?
    /// Diff decided deletion, but the server has not accepted its tombstone.
    var pendingDelete: Bool = false
    /// Time of the §4.7 deletion decision; 0 means none pending. §5.6 L1 uses it to recognize later inbound
    /// moves out of a deleted subtree (A9).
    var deleteDecidedAtMs: Int64 = 0
    /// Consecutive INVALID_MESSAGE refusals, for M3-2 §5.1's three-round give-up rule.
    var deleteRejectRounds: Int = 0
    /// Consecutive R-exec-13 key-repair refusals. A cursor with baseline but no entityId is otherwise
    /// rescheduled as create every round. After rekeyRejectGiveUpRounds = 3, stop rearming rejected repair.
    ///
    /// Unlike tombstone give-up, preserve deletedAtMs and reconciled: a live local row still exists. Give-up
    /// only stops proactive claiming; remote harvest or a later user content edit can restore the ID through
    /// normal publication, and applied resets this counter to nil.
    ///
    /// Must be optional, with nil equivalent to 0. Synthesized Codable decoding requires every nonoptional key
    /// even with a property default (verified in Swift 6.2). Existing build-822 JSON lacks this added field;
    /// making it nonoptional would invalidate all cursor files, trigger full replay and lose every reconciled
    /// baseline. Optional preserves compatibility without a formatVersion reset. Future fields must be
    /// optional or deliberately account for a format transition.
    var rekeyRejectRounds: Int?
    /// Finalized deletion time in both directions: set for landed remote tombstones and locally published
    /// tombstones acknowledged applied (§5.6). Omitting local acknowledgments would retain cursors forever
    /// after large cleanups. Preserve entityId/version for resurrection handling until whole-cursor expiry
    /// (§3.6).
    var deletedAtMs: Int64?
}

/// Typed accessors for a kind's two flags on PhiSpaceSyncTable. WritableKeyPath avoids misspelled
/// label-derived keys silently selecting another kind's full-replay flags.
struct OwnedKindFlags {
    let hadRecords: WritableKeyPath<PhiSpaceSyncTable, Bool>
    let replayedForEmptyTable: WritableKeyPath<PhiSpaceSyncTable, Bool>

    static let bookmarks = OwnedKindFlags(hadRecords: \.bookmarksHadRecords,
                                          replayedForEmptyTable: \.bookmarksReplayedForEmptyTable)
    static let pins = OwnedKindFlags(hadRecords: \.pinsHadRecords,
                                     replayedForEmptyTable: \.pinsReplayedForEmptyTable)
    static let urlRules = OwnedKindFlags(hadRecords: \.urlRulesHadRecords,
                                         replayedForEmptyTable: \.urlRulesReplayedForEmptyTable)
}

/// Storage for one kind's cursor table. Class-bound like PhiSpaceSyncStateStore: the engine retains/reuses the
/// same instance across rounds, and tests must observe mutations to their fake.
protocol PhiOwnedItemStateStore: AnyObject {
    /// Load the whole table and report unreadability in the return type. hadRecords comes from
    /// PhiSpaceSyncTable, outside this store (§3.5 single-copy rule). Keep the dependency explicit instead of
    /// reading another table.
    ///
    /// Silent cursor loss is dangerous: local syncIds and marker.json survive separately, leaving eligible
    /// rows without baselines. Publishing them as entityId-empty/version-0 creates hits server client_tag_hash
    /// upsert without version checks and can blindly overwrite account bookmarks. Report loss to force replay
    /// first.
    func load(hadRecords: Bool) -> (table: PhiOwnedItemTable, reportedLoss: Bool)
    /// False means table persistence failed (R-M3-4a-83). Discardable result preserves unrelated callers;
    /// engine write entry points consume it so Task 2b prevents marker advancement.
    @discardableResult func save(_ table: PhiOwnedItemTable) -> Bool
    /// Self-revocation (§9.1) deletes the file, never saves an empty table.
    func deleteFile()
}

/// One account-directory JSON file, at the path documented above.
final class FileOwnedItemStateStore: PhiOwnedItemStateStore {
    /// Exposed for tests asserting unreadable-load paths never write the file.
    let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Missing file, undecodable bytes, old formatVersion or zero cursors all return an empty table with
    /// reportedLoss = hadRecords and never write back. Replacing unreadable data with a valid empty file could
    /// hide real loss on later loads. Keep one guard because all four outcomes share this contract.
    func load(hadRecords: Bool) -> (table: PhiOwnedItemTable, reportedLoss: Bool) {
        guard let bytes = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(PhiOwnedItemTable.self, from: bytes),
              decoded.formatVersion >= PhiOwnedItemTable.currentFormatVersion,
              !decoded.cursors.isEmpty else {
            return (PhiOwnedItemTable(), hadRecords)
        }
        return (decoded, false)
    }

    /// Atomically persist the entire table (§3.5), like AccountUserDefaults.persistLocked. Do not retry inside
    /// the store (§11.4): next round reads the prior complete table or reports loss, both convergent. Log
    /// counts/error metadata only (R12).
    ///
    /// Return failure (R-M3-4a-83) so the engine withholds this page's marker (§2.5 item 6) and replays the
    /// whole round next time, not a separate partial-write retry queue.
    @discardableResult
    func save(_ table: PhiOwnedItemTable) -> Bool {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try JSONEncoder().encode(table).write(to: fileURL, options: .atomic)
            return true
        } catch {
            AppLogError("[phi-sync] owned-item cursor save failed cursors=\(table.cursors.count) "
                + "(\(PhiSyncLog.describe(error)))")
            return false
        }
    }

    func deleteFile() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch {
            AppLogWarn("[phi-sync] owned-item cursor delete failed (\(PhiSyncLog.describe(error)))")
        }
    }
}

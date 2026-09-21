// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Combine
import Foundation
import SwiftData

extension LocalStore {

    /// Stable persisted target for URL rules that open matches in an
    /// ephemeral Kiosk window instead of a Space. This is a wire value shared
    /// with Chromium's `phi::kKioskRuleTargetId`; it must never change after
    /// rules using it have been stored.
    static let kioskURLRuleTargetId = "__phi_kiosk__"

    /// Value-typed view of a `SpaceURLRule` used at the LocalStore boundary.
    /// `applyURLRuleEditsThrowing(upserts:deletedIds:)` accepts these so callers never hold SwiftData models
    /// across contexts. The write body resolves stable `id` and writes only supplied units.
    ///
    /// Each merge unit is Optional: nil literally means omitted (§4.3 item 4 / R-M3-4a-72). Omitted units
    /// cause no writes, stamps or pending-edit contribution even if the stored value differs. Supplied units
    /// are compared against current rows and equal values also write/stamp nothing (ruling 2). Content members
    /// share one timestamp and one `ContentUnit`; a host-only change remains a whole-group wire write.
    ///
    /// Nil content preserves host/pathPrefix/askBeforeRouting and their stamp; nil spaceId preserves target
    /// and targetUpdatedDate, including concurrent remote edits; nil sortOrder preserves existing position or
    /// appends new rows; nil createdDate preserves existing dates or uses Date() on insertion. Default id
    /// remains UUID().uuidString (omission remints it, R-M3-4a-13).
    ///
    /// Field-dirty callers (M5 / 8b-4) use the synthesized memberwise initializer; the trailing extension
    /// provides a flat convenience initializer.
    struct URLRuleDraft {
        /// Content group: host/pathPrefix/askBeforeRouting share `contentUpdatedDate` (R-M3-4a-48).
        /// Construction calls `normalizedRule`, one of the three §8.1 sites, so the stored unit is a
        /// normalization fixed point.
        struct ContentUnit: Equatable {
            var host: String
            var pathPrefix: String?
            var askBeforeRouting: Bool

            init(host: String, pathPrefix: String? = nil, askBeforeRouting: Bool = false) {
                let normalized = LocalStore.normalizedRule(host: host, pathPrefix: pathPrefix)
                self.host = normalized.host
                self.pathPrefix = normalized.pathPrefix
                self.askBeforeRouting = askBeforeRouting
            }
        }

        var id: String = UUID().uuidString
        var syncId: String?
        var content: ContentUnit?
        var spaceId: String?
        var sortOrder: Int?
        var createdDate: Date?
        var contentUpdatedDate: Date?

        /// Compatibility read for pre-Task 11 callers (SpaceManager's two optimistic pushes and
        /// URLRouterTests): absent content returns its default empty host. Task 11 / 8b-4 use the content unit
        /// directly.
        var host: String { content?.host ?? "" }

        /// Compatibility read (see `host`): nil content returns nil.
        var pathPrefix: String? { content?.pathPrefix }

        /// Compatibility read (see `host`): nil content returns false.
        var askBeforeRouting: Bool { content?.askBeforeRouting ?? false }
    }

    /// Default read API excludes soft-deleted rows (`deletedDate != nil`), which are visible only to sync
    /// (R-M3-4a-51). `urlRulesPublisher()` reads through this API and inherits the filter.
    @MainActor
    func getAllURLRules() -> [SpaceRoutingRule] {
        guard let context = mainContext else { return [] }
        do {
            let descriptor = FetchDescriptor<SpaceURLRule>(
                predicate: #Predicate { $0.deletedDate == nil },
                sortBy: [SortDescriptor(\.spaceId), SortDescriptor(\.sortOrder)]
            )
            return try context.fetch(descriptor).map { model in
                SpaceRoutingRule(id: model.id, spaceId: model.spaceId, host: model.host,
                                 pathPrefix: model.pathPrefix,
                                 askBeforeRouting: model.askBeforeRouting,
                                 sortOrder: model.sortOrder, createdDate: model.createdDate,
                                 syncId: model.syncId, deletedDate: model.deletedDate)
            }
        } catch {
            AppLogError("[LocalStore] getAllURLRules failed: \(error)")
            return []
        }
    }

    @MainActor
    func getURLRules(forSpaceId spaceId: String) -> [SpaceRoutingRule] {
        guard let context = mainContext else { return [] }
        do {
            let descriptor = FetchDescriptor<SpaceURLRule>(
                predicate: #Predicate { $0.spaceId == spaceId && $0.deletedDate == nil },
                sortBy: [SortDescriptor(\.sortOrder)]
            )
            return try context.fetch(descriptor).map { model in
                SpaceRoutingRule(id: model.id, spaceId: model.spaceId, host: model.host,
                                 pathPrefix: model.pathPrefix,
                                 askBeforeRouting: model.askBeforeRouting,
                                 sortOrder: model.sortOrder, createdDate: model.createdDate,
                                 syncId: model.syncId, deletedDate: model.deletedDate)
            }
        } catch {
            AppLogError("[LocalStore] getURLRules(forSpaceId:) failed: \(error)")
            return []
        }
    }

    // MARK: - Sole public write entry (R-M3-4a-49 / §4.3 item 5)

    /// Apply all changes from one editor Save/agent call in one transaction. There is no nonthrowing sibling:
    /// absent `writeActor` throws `.storeUnavailable`; any body error makes `performThrowing` roll back the
    /// entire batch. Callers must distinguish silent failure from successful landing (R-M3-3-14).
    func applyURLRuleEditsThrowing(upserts: [URLRuleDraft], deletedIds: Set<String>) async throws {
        try await performBackgroundWriteAndWaitThrowing { context in
            try self.applyURLRuleEditsBody(upserts: upserts, deletedIds: deletedIds, in: context)
        }
    }

    /// Eight steps within one context.
    private func applyURLRuleEditsBody(upserts: [URLRuleDraft],
                                       deletedIds: Set<String>,
                                       in context: ModelContext) throws {
        // Step 1: one `now`, one full-table fetch including soft-deleted rows (R-M3-4a-56), and two indices.
        // Index stable IDs across the entire table, not per target-Space bucket (R-M3-4a-80).
        let now = Date()
        var rows = try context.fetch(FetchDescriptor<SpaceURLRule>())
        var byId: [String: SpaceURLRule] = [:]
        var bySyncId: [String: SpaceURLRule] = [:]
        for row in rows {
            byId[row.id] = row
            if let syncId = row.syncId {
                bySyncId[syncId] = row
            }
        }
        var touchedBuckets: Set<String> = []
        // Step 8 inputs: rows with an explicit sortOrder and rows inserted in step 6, ranked with Int.max.
        var placements: [String: Int] = [:]
        var insertedIds: Set<String> = []
        // Step 9 inputs: rows named by this batch, and those that actually wrote a unit in steps 4/5.
        var upsertedIds: [String] = []
        var wroteUnit: Set<String> = []

        for draft in upserts {
            // Step 2: resolve by draft.id, then draft.syncId. A syncId match also adopts draft.id (ruling 3
            // legacy fallback): editor Row initialization replaces legacy non-UUID IDs, so syncId preserves
            // identity.
            var located = byId[draft.id]
            var adoptsDraftId = false
            if located == nil, let syncId = draft.syncId, let bySync = bySyncId[syncId] {
                located = bySync
                adoptsDraftId = true
            }
            // Step 2b: a soft-deleted match (R-M3-4a-104 / ruling 8). The index includes rows already
            // soft-deleted by M2 or inbound tombstones.
            var mintsFreshId = false
            if let row = located, row.deletedDate != nil {
                guard draft.syncId == nil else {
                    // Sync landing must use its two per-row primitives, never this entry: fail closed.
                    throw LocalStoreWriteError.rowAlreadyMapped
                }
                // Editor/agent path: leave the soft-deleted row untouched while it awaits tombstone `.applied`
                // or §8.4.7's 30-day purge. Insert with a fresh ID instead, since the old row still owns
                // draft.id under the unique constraint.
                located = nil
                mintsFreshId = true
            }

            if let row = located {
                // Step 3: two identity guards, matching LocalStore+Bookmark.swift:2196-2199. A row can claim
                // identity only once: changing UUID would leave the old identity without a local row and cause
                // diff to tombstone its remote entity.
                if let draftSyncId = draft.syncId {
                    // (a) The row already has another syncId.
                    if let rowSyncId = row.syncId, rowSyncId != draftSyncId {
                        throw LocalStoreWriteError.rowAlreadyMapped
                    }
                    // (b) Another local row ID already owns this syncId.
                    if let owner = bySyncId[draftSyncId], owner !== row {
                        throw LocalStoreWriteError.rowAlreadyMapped
                    }
                    if row.syncId == nil {
                        // Claiming is not editing: write identity without stamping or setting pending edit.
                        row.syncId = draftSyncId
                        bySyncId[draftSyncId] = row
                    }
                }
                if adoptsDraftId {
                    byId[row.id] = nil
                    row.id = draft.id
                    byId[draft.id] = row
                }
                let rowId = row.id
                upsertedIds.append(rowId)

                // Step 4: content members share one stamp (R-M3-4a-48). Skip nil units entirely. Normalize
                // supplied units idempotently (§8.1's third site; landing bypasses drafts), compare each
                // field, and write only differences plus contentUpdatedDate = now. Equal content writes
                // nothing.
                if let unit = draft.content {
                    let normalized = LocalStore.normalizedRule(host: unit.host, pathPrefix: unit.pathPrefix)
                    var contentChanged = false
                    if row.host != normalized.host {
                        row.host = normalized.host
                        contentChanged = true
                    }
                    if row.pathPrefix != normalized.pathPrefix {
                        row.pathPrefix = normalized.pathPrefix
                        contentChanged = true
                    }
                    if row.askBeforeRouting != unit.askBeforeRouting {
                        row.askBeforeRouting = unit.askBeforeRouting
                        contentChanged = true
                    }
                    if contentChanged {
                        row.contentUpdatedDate = now
                        wroteUnit.insert(rowId)
                    }
                }

                // Step 5: nil target preserves spaceId and targetUpdatedDate even after concurrent remote
                // edits (§4.3 item 4); only record the current bucket. A changed target updates both fields
                // and records old/new buckets for normalization. Preserve syncId and content: changing target
                // moves the same row between buckets (R-M3-4a-80).
                if let spaceId = draft.spaceId {
                    if spaceId != row.spaceId {
                        touchedBuckets.insert(row.spaceId)
                        row.spaceId = spaceId
                        row.targetUpdatedDate = now
                        wroteUnit.insert(rowId)
                    }
                    touchedBuckets.insert(spaceId)
                } else {
                    touchedBuckets.insert(row.spaceId)
                }
                if let sortOrder = draft.sortOrder {
                    placements[rowId] = sortOrder
                }
            } else {
                // Step 6: insert after no identity match, or a nil-syncId draft matching a soft-deleted row
                // (step 2b). New rows cannot inherit missing units; reject incomplete drafts instead of
                // silently reporting success (R-M3-3-14).
                guard let unit = draft.content, let spaceId = draft.spaceId else {
                    throw LocalStoreWriteError.noCandidateSurvived
                }
                let normalized = LocalStore.normalizedRule(host: unit.host, pathPrefix: unit.pathPrefix)
                // Mint syncId on insertion (R-M3-4a-23), or preserve a supplied draft.syncId for sync landing.
                let syncId = draft.syncId ?? UUID().uuidString.lowercased()
                // Apply step 3 guard (b) before insertion.
                guard bySyncId[syncId] == nil else {
                    throw LocalStoreWriteError.rowAlreadyMapped
                }
                // Use draft.id if no row matched, preserving the editor row's position (R-M3-4a-101). Mint a
                // fresh UUID when a soft-deleted row owns that ID.
                let id = mintsFreshId ? UUID().uuidString.lowercased() : draft.id
                // Ruling 5: do not mint a content stamp for new rows; baseline-free projection uses
                // contentUpdatedDate ?? createdDate, and createdDate is current. sortOrder is a placeholder
                // normalized in step 8.
                let row = SpaceURLRule(
                    id: id,
                    spaceId: spaceId,
                    host: normalized.host,
                    pathPrefix: normalized.pathPrefix,
                    askBeforeRouting: unit.askBeforeRouting,
                    sortOrder: Int.max,
                    createdDate: draft.createdDate ?? Date(),
                    syncId: syncId,
                    contentUpdatedDate: draft.contentUpdatedDate,
                    targetUpdatedDate: nil,
                    deletedDate: nil,
                    pendingLocalEdit: true,
                    mergePartnerSyncId: nil
                )
                context.insert(row)
                rows.append(row)
                byId[id] = row
                bySyncId[syncId] = row
                insertedIds.insert(id)
                upsertedIds.append(id)
                if let sortOrder = draft.sortOrder {
                    placements[id] = sortOrder
                }
                touchedBuckets.insert(spaceId)
            }
        }

        // Step 7: soft-delete deletedIds (R-M3-4a-41) without touching pendingLocalEdit; deletion is not
        // editing (R-M3-4a-69). Ignore absent rows instead of throwing rowNotFound, since concurrent landing
        // may have hard-deleted them. Record their buckets to close index gaps.
        for id in deletedIds {
            guard let row = byId[id], row.deletedDate == nil else { continue }
            row.deletedDate = now
            touchedBuckets.insert(row.spaceId)
        }

        // Step 8: densify each touched bucket's live rows. Sort unplaced rows by prior (sortOrder, id), with
        // new rows at Int.max. Sort explicitly placed rows by (requested index, id), inserting each at
        // min(requested index, current count). Write only changed final 0…n-1 indices, without stamps
        // (R-M3-4a-11) or additional pending-edit flags.
        var reorderedIds: Set<String> = []
        for bucket in touchedBuckets {
            let live = rows.filter { $0.spaceId == bucket && $0.deletedDate == nil }
            var sequence = live
                .filter { placements[$0.id] == nil }
                .sorted { lhs, rhs in
                    let l = insertedIds.contains(lhs.id) ? Int.max : lhs.sortOrder
                    let r = insertedIds.contains(rhs.id) ? Int.max : rhs.sortOrder
                    if l != r { return l < r }
                    return lhs.id < rhs.id
                }
            let placed = live
                .filter { placements[$0.id] != nil }
                .sorted { lhs, rhs in
                    let l = placements[lhs.id] ?? Int.max
                    let r = placements[rhs.id] ?? Int.max
                    if l != r { return l < r }
                    return lhs.id < rhs.id
                }
            for row in placed {
                let requested = placements[row.id] ?? sequence.count
                sequence.insert(row, at: min(max(requested, 0), sequence.count))
            }
            for (index, row) in sequence.enumerated() where row.sortOrder != index {
                row.sortOrder = index
                reorderedIds.insert(row.id)
            }
        }

        // Step 9: set pendingLocalEdit only for upsert rows whose content, target or position actually changed
        // in steps 4/5/8 (§4.3). Neither omitted nor equal units contribute. Do not rewrite flags already
        // true.
        for id in upsertedIds where wroteUnit.contains(id) || reorderedIds.contains(id) {
            if let row = byId[id], !row.pendingLocalEdit {
                row.pendingLocalEdit = true
            }
        }
    }

    // MARK: - Sync read API and full-table index (R-M3-4a-51 / R-M3-4a-56 / R-M3-4a-80)

    /// Sync read API: the entire table including soft-deleted rows, ordered by (spaceId, sortOrder, id). Used
    /// by AccountPhiURLRuleAccess snapshots/liveOwners and urlRuleChangesPublisher value snapshots. Throw on
    /// read failure (R-exec-3), unlike UI getAllURLRules() returning []: diff would tombstone every cursor for
    /// an empty result.
    func allURLRuleModelsIncludingDeleted(in context: ModelContext) throws -> [SpaceURLRule] {
        try context.fetch(FetchDescriptor<SpaceURLRule>(
            sortBy: [SortDescriptor(\.spaceId), SortDescriptor(\.sortOrder), SortDescriptor(\.id)]
        ))
    }

    /// Build one full-table syncId index including soft-deleted rows per write (R-M3-4a-56 / R-M3-4a-80).
    /// Nil-syncId rows remain only in rows, the final normalization domain. Both per-row primitives
    /// resolve/register here, yielding one fetch per N-operation batch instead of N fetches.
    struct URLRuleTableIndex {
        private(set) var rows: [SpaceURLRule]
        private(set) var bySyncId: [String: SpaceURLRule]

        init(rows: [SpaceURLRule]) {
            self.rows = rows
            var bySyncId: [String: SpaceURLRule] = [:]
            for row in rows {
                if let syncId = row.syncId, bySyncId[syncId] == nil {
                    bySyncId[syncId] = row
                }
            }
            self.bySyncId = bySyncId
        }

        mutating func insert(_ row: SpaceURLRule) {
            rows.append(row)
            if let syncId = row.syncId, bySyncId[syncId] == nil {
                bySyncId[syncId] = row
            }
        }

        mutating func remove(_ row: SpaceURLRule) {
            rows.removeAll { $0 === row }
            if let syncId = row.syncId, bySyncId[syncId] === row {
                bySyncId[syncId] = nil
            }
        }

        /// Update the index after §8.4.2 M1 re-key: remove the old key if it points to this row, then register
        /// the row's new syncId. Later updates in this write resolve through the new identity.
        mutating func rekey(_ row: SpaceURLRule, from previous: String?) {
            if let previous, bySyncId[previous] === row {
                bySyncId[previous] = nil
            }
            if let syncId = row.syncId, bySyncId[syncId] == nil {
                bySyncId[syncId] = row
            }
        }
    }

    /// Build the index with one full SpaceURLRule fetch including soft-deleted rows.
    func urlRuleTableIndex(in context: ModelContext) throws -> URLRuleTableIndex {
        URLRuleTableIndex(rows: try context.fetch(FetchDescriptor<SpaceURLRule>()))
    }

    // MARK: - Two per-row primitives for sync landing

    // Each has a throwing wrapper and an internal body accepting index/context. applyURLRuleSyncBatchBody
    // composes those bodies in one write; nesting another serialized write would deadlock (R-exec-2). Both
    // resolve against the full URLRuleTableIndex including soft-deleted rows (R-M3-4a-56), avoiding duplicate
    // syncIds. Neither touches pendingLocalEdit: engine writes never set it.

    /// Throwing sibling used ONLY by the sync layer — see `updateBookmarkThrowing`.
    func upsertURLRuleThrowing(syncId: String,
                               spaceId: String,
                               host: String,
                               pathPrefix: String?,
                               ask: Bool,
                               sortOrder: Int,
                               createdDate: Date,
                               contentUpdatedDate: Date?,
                               targetUpdatedDate: Date?) async throws {
        try await performBackgroundWriteAndWaitThrowing { context in
            var index = try self.urlRuleTableIndex(in: context)
            try self.upsertURLRuleBody(syncId: syncId,
                                       spaceId: spaceId,
                                       host: host,
                                       pathPrefix: pathPrefix,
                                       ask: ask,
                                       sortOrder: sortOrder,
                                       createdDate: createdDate,
                                       contentUpdatedDate: contentUpdatedDate,
                                       targetUpdatedDate: targetUpdatedDate,
                                       index: &index,
                                       in: context)
        }
    }

    /// On match, update nine fields after host/pathPrefix normalization, copying both input stamps without
    /// minting now (R-M3-4a-20; precedent LocalStore+Bookmark.swift:2073). If soft-deleted, clear deletedDate
    /// and mergePartnerSyncId in the same write. If absent, create with a new local ID and supplied syncId;
    /// never throw rowNotFound (R-M3-4a-42(a)). Return the row for bucket tracking.
    @discardableResult
    func upsertURLRuleBody(syncId: String,
                           spaceId: String,
                           host: String,
                           pathPrefix: String?,
                           ask: Bool,
                           sortOrder: Int,
                           createdDate: Date,
                           contentUpdatedDate: Date?,
                           targetUpdatedDate: Date?,
                           index: inout URLRuleTableIndex,
                           in context: ModelContext) throws -> SpaceURLRule {
        let normalized = LocalStore.normalizedRule(host: host, pathPrefix: pathPrefix)
        guard let row = index.bySyncId[syncId] else {
            let row = SpaceURLRule(
                id: UUID().uuidString,
                spaceId: spaceId,
                host: normalized.host,
                pathPrefix: normalized.pathPrefix,
                askBeforeRouting: ask,
                sortOrder: sortOrder,
                createdDate: createdDate,
                syncId: syncId,
                contentUpdatedDate: contentUpdatedDate,
                targetUpdatedDate: targetUpdatedDate,
                deletedDate: nil,
                pendingLocalEdit: false,
                mergePartnerSyncId: nil
            )
            context.insert(row)
            index.insert(row)
            return row
        }
        // Claim identity once, as in LocalStore+Bookmark.swift:2196-2199. syncId lookup guarantees this today;
        // retain the guard so future addressing changes throw instead of silently replacing identity
        // (R-M3-3-14).
        guard row.syncId == nil || row.syncId == syncId else {
            throw LocalStoreWriteError.rowAlreadyMapped
        }
        row.syncId = syncId
        row.spaceId = spaceId
        row.host = normalized.host
        row.pathPrefix = normalized.pathPrefix
        row.askBeforeRouting = ask
        row.sortOrder = sortOrder
        row.createdDate = createdDate
        row.contentUpdatedDate = contentUpdatedDate
        row.targetUpdatedDate = targetUpdatedDate
        if row.deletedDate != nil {
            row.deletedDate = nil
            row.mergePartnerSyncId = nil
        }
        return row
    }

    /// Throwing sibling used ONLY by the sync layer — see `updateBookmarkThrowing`.
    func hardDeleteURLRuleThrowing(syncId: String) async throws {
        try await performBackgroundWriteAndWaitThrowing { context in
            var index = try self.urlRuleTableIndex(in: context)
            try self.hardDeleteURLRuleBody(syncId: syncId, index: &index, in: context)
        }
    }

    /// Hard-delete with context.delete for inbound tombstones. Return nil when already absent (T3); otherwise
    /// return the bucket captured before deletion.
    @discardableResult
    func hardDeleteURLRuleBody(syncId: String,
                               index: inout URLRuleTableIndex,
                               in context: ModelContext) throws -> String? {
        var bucket: String?
        // index.rows is a value copy; mutating index during iteration does not affect traversal.
        for row in index.rows where row.syncId == syncId {
            // The same identity guard as upsertURLRuleBody.
            guard row.syncId == nil || row.syncId == syncId else {
                throw LocalStoreWriteError.rowAlreadyMapped
            }
            if bucket == nil {
                bucket = row.spaceId
            }
            context.delete(row)
            index.remove(row)
        }
        return bucket
    }

    // MARK: - §8.4.2 M1 re-key (first of §4.3's six new primitives)

    /// Throwing sibling used ONLY by the sync layer — see updateBookmarkThrowing.
    ///
    /// §8.4.2 M1 re-key resolves by local row ID, supplied by context.pairs rather than OwnedItemApplyStep. An
    /// equal syncId returns idempotently without writes; a soft-deleted row throws rowNotFound and cannot be
    /// claimed. If another local row owns the desired syncId, throw rowAlreadyMapped and roll back the entire
    /// batch (R-M3-4a-80). Re-key in place: deleting/recreating would temporarily orphan the identity or
    /// duplicate the row, causing §5.7 diff to tombstone it.
    func rekeyURLRuleThrowing(localId: String, to syncId: String) async throws {
        try await performBackgroundWriteAndWaitThrowing { context in
            var index = try self.urlRuleTableIndex(in: context)
            try self.rekeyURLRuleBody(localId: localId, to: syncId, index: &index, in: context)
        }
    }

    /// R-exec-2 body for use inside the batch's existing write; nested serialized writes deadlock. Resolve
    /// local ID and check syncId collisions across the full table, including soft-deleted rows (R-M3-4a-56 /
    /// R-M3-4a-80). Write only syncId: no stamps, pending flags or mergePartnerSyncId changes (RR10-8 /
    /// R-M3-4a-69). The bookmark claim guard does not apply: rule re-key must replace its nonnil identity
    /// minted on insertion.
    func rekeyURLRuleBody(localId: String,
                          to syncId: String,
                          index: inout URLRuleTableIndex,
                          in context: ModelContext) throws {
        guard let row = index.rows.first(where: { $0.id == localId }) else {
            throw LocalStoreWriteError.rowNotFound
        }
        guard row.deletedDate == nil else {
            throw LocalStoreWriteError.rowNotFound
        }
        // 1. Accept equal identities idempotently (CASE M-32 (a)); otherwise CASE M-13 replay would throw.
        if row.syncId == syncId { return }
        // R-M3-4a-80: another local ID owns this account identity. Only local id is unique in the schema;
        // allowing competing rows would leave one identity unclaimed and tombstoned next round.
        if let owner = index.bySyncId[syncId], owner !== row {
            throw LocalStoreWriteError.rowAlreadyMapped
        }
        let previous = row.syncId
        row.syncId = syncId
        index.rekey(row, from: previous)
    }

    // MARK: - §8.4.3 M2 primitives (second through fourth of §4.3's six, 8b-2)

    // All three share plan ruling 5: resolve in URLRuleTableIndex including soft-deleted rows (R-M3-4a-56) and
    // use §4.3's rowAlreadyMapped guard from LocalStore+Bookmark.swift:2196-2199. A missing syncId returns
    // without writes, asserting in DEBUG but never throwing. M2 inputs come from the same transaction's
    // projection and must resolve; throwing would endlessly replay and reject the whole page (§5.5, as in CASE
    // M-13). Never touch pendingLocalEdit (R-M3-4a-69 / RR5-8) or mint stamps. setURLRuleContentGroupBody
    // copies its source stamp (D33 / §8.4.1 item 5).

    /// Throwing sibling used ONLY by sync — see updateBookmarkThrowing. Shared by §8.4.3 step 2(b) and editor
    /// deletion: write deletedDate = Date() and mergePartnerSyncId together in one SwiftData transaction
    /// (RR8-4). The editor passes nil.
    func softDeleteURLRuleThrowing(syncId: String, mergePartnerSyncId: String?) async throws {
        try await performBackgroundWriteAndWaitThrowing { context in
            var index = try self.urlRuleTableIndex(in: context)
            try self.softDeleteURLRuleBody(syncId: syncId,
                                           mergePartnerSyncId: mergePartnerSyncId,
                                           index: &index, in: context)
        }
    }

    /// Return the soft-deleted row's bucket, or nil without writes if identity is absent. Callers normalize
    /// its resulting gap: sortOrder is the third routing-specificity term, before the tie-break key. Never
    /// refresh an existing deletedDate, which would restart §8.4.7's 30-day retention clock.
    @discardableResult
    func softDeleteURLRuleBody(syncId: String,
                               mergePartnerSyncId: String?,
                               index: inout URLRuleTableIndex,
                               in context: ModelContext) throws -> String? {
        guard let row = index.bySyncId[syncId] else {
            assertionFailure("url rule soft delete: the merge tail addressed a row that is not there")
            return nil
        }
        guard row.syncId == nil || row.syncId == syncId else {
            throw LocalStoreWriteError.rowAlreadyMapped
        }
        // Write both columns together: a failure between deletion and partner assignment would prevent §8.4.4
        // partner lookup from rescuing the edit.
        if row.deletedDate == nil { row.deletedDate = Date() }
        if row.mergePartnerSyncId != mergePartnerSyncId {
            row.mergePartnerSyncId = mergePartnerSyncId
        }
        return row.spaceId
    }

    /// Throwing sibling used ONLY by sync — see updateBookmarkThrowing. §8.4.3 step 1 writes only the partner
    /// hint; nil clears it for both clearing rules. Equal values write nothing (RR11-8), a second defense
    /// after mergePointerPass's primary precondition.
    func setURLRuleMergePartnerThrowing(syncId: String, mergePartnerSyncId: String?) async throws {
        try await performBackgroundWriteAndWaitThrowing { context in
            var index = try self.urlRuleTableIndex(in: context)
            try self.setURLRuleMergePartnerBody(syncId: syncId,
                                                mergePartnerSyncId: mergePartnerSyncId,
                                                index: &index, in: context)
        }
    }

    func setURLRuleMergePartnerBody(syncId: String,
                                    mergePartnerSyncId: String?,
                                    index: inout URLRuleTableIndex,
                                    in context: ModelContext) throws {
        guard let row = index.bySyncId[syncId] else {
            assertionFailure("url rule merge partner: the merge tail addressed a row that is not there")
            return
        }
        guard row.syncId == nil || row.syncId == syncId else {
            throw LocalStoreWriteError.rowAlreadyMapped
        }
        guard row.mergePartnerSyncId != mergePartnerSyncId else { return }
        row.mergePartnerSyncId = mergePartnerSyncId
    }

    /// Throwing sibling used ONLY by sync — see updateBookmarkThrowing. §8.4.3 step 2(a) copies the entire
    /// winning content group: three fields and their shared timestamp. Preserve sortOrder, targetUpdatedDate,
    /// deletedDate and pendingLocalEdit. Do not reuse upsertURLRuleThrowing, which also requires order
    /// (conflicting with page normalization) and target timestamp (untouched by convergence).
    func setURLRuleContentGroupThrowing(syncId: String, host: String, pathPrefix: String?,
                                        ask: Bool, contentUpdatedDate: Date) async throws {
        try await performBackgroundWriteAndWaitThrowing { context in
            var index = try self.urlRuleTableIndex(in: context)
            try self.setURLRuleContentGroupBody(syncId: syncId, host: host,
                                                pathPrefix: pathPrefix, ask: ask,
                                                contentUpdatedDate: contentUpdatedDate,
                                                index: &index, in: context)
        }
    }

    func setURLRuleContentGroupBody(syncId: String, host: String, pathPrefix: String?,
                                    ask: Bool, contentUpdatedDate: Date,
                                    index: inout URLRuleTableIndex,
                                    in context: ModelContext) throws {
        guard let row = index.bySyncId[syncId] else {
            assertionFailure("url rule content group: the merge tail addressed a row that is not there")
            return
        }
        guard row.syncId == nil || row.syncId == syncId else {
            throw LocalStoreWriteError.rowAlreadyMapped
        }
        // §8.1's fourth normalization site is idempotent; V11-backfilled source rows may still be
        // unnormalized.
        let normalized = LocalStore.normalizedRule(host: host, pathPrefix: pathPrefix)
        if row.host != normalized.host { row.host = normalized.host }
        if row.pathPrefix != normalized.pathPrefix { row.pathPrefix = normalized.pathPrefix }
        if row.askBeforeRouting != ask { row.askBeforeRouting = ask }
        // Copy the source stamp (D33); minting now would give a mechanically moved rule false freshness over a
        // real user edit.
        if row.contentUpdatedDate != contentUpdatedDate {
            row.contentUpdatedDate = contentUpdatedDate
        }
    }

    // MARK: - §8.4.4 M3 transfer (fifth of §4.3's six primitives, 8b-3)

    /// Throwing sibling used ONLY by sync — see updateBookmarkThrowing. M3 edit transfer (§8.4.4) compares
    /// merge units against W using LWW, writing only whole winning groups. Return the number written (0…2) for
    /// transferred accounting (§13.2). Set W.pendingLocalEdit only if a unit wins; otherwise write nothing
    /// (§8.4.5).
    ///
    /// For each W unit, use max(row stamp, effective account stamp) (R-M3-4a-98). New rows and baseline-only
    /// rebaselining can leave row stamps behind; row-only comparison could overwrite newer account data when
    /// this page has no W update, beyond R-M3-4a-93 phase-order protection. targetEffectiveStamps comes from
    /// URLRuleApplyBatch.accountStamps, shared with the M2 tail hook, with no new protocol member. Missing
    /// account stamps fall back to row stamps.
    ///
    /// This primitive knows only W. The batch executor performs R-M3-4a-102's unchanged-source check for X.
    /// Resolve across the full table including soft-deleted rows (R-M3-4a-56); absent toSyncId returns 0
    /// without writing or throwing.
    @discardableResult
    func transferURLRuleEditThrowing(toSyncId: String, source: RuleProjection,
                                     targetEffectiveStamps: URLRuleEffectiveStamps) async throws
        -> Int {
        try await performBackgroundWriteAndWaitThrowing { context -> Int in
            var index = try self.urlRuleTableIndex(in: context)
            return try self.transferURLRuleEditBody(toSyncId: toSyncId, source: source,
                                                    targetEffectiveStamps: targetEffectiveStamps,
                                                    index: &index, in: context).written
        }
    }

    /// Actual transfer result. Non-nil movedFrom means the target unit won and W changed buckets; normalize
    /// both source and destination buckets (R-M3-4a-3).
    struct URLRuleTransferResult: Equatable {
        var written = 0
        /// A losing content group counts once as superseded_by_delete (§13.3).
        var contentSuperseded = false
        var movedFrom: String?
    }

    /// R-exec-2 body runs within the batch's write and index. Delegate all decisions to
    /// URLRuleKind.transferDecision(target:source:targetEffectiveStamps:) so production landing and the fake
    /// share one winner rule.
    @discardableResult
    func transferURLRuleEditBody(toSyncId: String, source: RuleProjection,
                                 targetEffectiveStamps: URLRuleEffectiveStamps,
                                 index: inout URLRuleTableIndex,
                                 in context: ModelContext) throws -> URLRuleTransferResult {
        var out = URLRuleTransferResult()
        guard let row = index.bySyncId[toSyncId] else {
            // Missing target: no write and no throw, matching softDeleteURLRuleBody.
            out.contentSuperseded = true
            return out
        }
        // The same identity guard as upsertURLRuleBody.
        guard row.syncId == nil || row.syncId == toSyncId else {
            throw LocalStoreWriteError.rowAlreadyMapped
        }
        let decision = URLRuleKind.transferDecision(target: Self.projectURLRule(row),
                                                    source: source,
                                                    targetEffectiveStamps: targetEffectiveStamps)
        out.contentSuperseded = decision.contentSuperseded
        out.written = decision.written
        if decision.writesContent {
            // Normalize idempotently (§8.1), including legacy V11 rows. Write the three source fields with
            // their shared source stamp; never mint now (D33 / §8.4.1 item 5).
            let normalized = LocalStore.normalizedRule(host: source.host,
                                                       pathPrefix: source.pathPrefix)
            row.host = normalized.host
            row.pathPrefix = normalized.pathPrefix
            row.askBeforeRouting = source.askBeforeRouting
            row.contentUpdatedDate = source.contentUpdatedDate
        }
        if decision.writesTarget, let spaceId = source.targetSpaceId {
            if row.spaceId != spaceId {
                out.movedFrom = row.spaceId
                row.spaceId = spaceId
            }
            row.targetUpdatedDate = source.targetUpdatedDate
        }
        // §8.4.5: set the flag only when written > 0. Unconditional setting would leave W permanently
        // non-quiescent, preventing M2 convergence and yielding to every remote deletion.
        if out.written > 0, !row.pendingLocalEdit { row.pendingLocalEdit = true }
        return out
    }

    // MARK: - §8.4.5's two flag-clearing paths (sixth of §4.3's six primitives, 8b-4)

    // Exactly two clearing paths are permitted. Both require every current merge unit to equal the caller's
    // baseline at millisecond precision. Path (a) also clears mergePartnerSyncId in the same row write (§8.4.3
    // lifecycle table row 2); (b) never touches it.
    //
    // Read, compare and write in one context transaction (R-M3-4a-79 / R-M3-4a-91). Checking only
    // pendingLocalEdit could clear E2's flag after a user saves between the E1 snapshot and this transaction;
    // a later remote tombstone would then bypass §8.4.4 (α) yielding and hard-delete the unpublished edit.

    /// Throwing sibling used ONLY by sync — see updateBookmarkThrowing. Clearing path (a) (§8.4.5 and §8.4.3
    /// lifecycle table row 2) uses one row write/transaction (R-M3-4a-79). Called by the urlRules
    /// registration's notePublishApplied only for live publications acknowledged applied, never tombstones.
    ///
    /// Return only whether pendingLocalEdit was cleared; clearing mergePartnerSyncId is separately accounted
    /// (M-7d). Missing rows return false without writes: newly minted identities are unavailable until
    /// claimIdentities writes them back, so ruling 5 places this call afterward.
    @discardableResult
    func clearPendingLocalEditThrowing(syncId: String,
                                       ifProjectionEquals confirmed: RuleProjection) async throws
        -> Bool {
        try await performBackgroundWriteAndWaitThrowing { context -> Bool in
            try self.clearPendingLocalEditBody(syncId: syncId, ifProjectionEquals: confirmed,
                                               in: context)
        }
    }

    private func clearPendingLocalEditBody(syncId: String,
                                           ifProjectionEquals confirmed: RuleProjection,
                                           in context: ModelContext) throws -> Bool {
        // Resolve against the full table including soft-deleted rows (R-M3-4a-56), like the other per-row
        // primitives.
        let index = try urlRuleTableIndex(in: context)
        guard let row = index.bySyncId[syncId] else { return false }
        // §8.4.3's first clearing rule applies now, after the edit reaches the account. Clear the pointer with
        // the flag in one transaction/row write, avoiding extra publisher/routing refresh events and a crash
        // between the writes (CASE M-7). Equal values write nothing (RR11-8).
        if row.mergePartnerSyncId != nil { row.mergePartnerSyncId = nil }
        guard row.pendingLocalEdit else { return false }
        let current = URLRuleKind.clearingProjection(of: Self.projectURLRule(row))
        guard URLRuleKind.clearingProjectionMatches(row: current, confirmed: confirmed) else {
            // Current row differs from the acknowledged baseline: the user saved E2 while E1 was in flight.
            // Preserve the flag until path (b) repairs it or E2 itself receives applied (CASE M-7b).
            return false
        }
        row.pendingLocalEdit = false
        return true
    }

    /// Throwing sibling used ONLY by sync — see updateBookmarkThrowing. Clearing path (b), §8.4.5, receives
    /// candidate identities and their individual comparison baselines (R-M3-4a-91). entries[syncId] is the
    /// row-side RuleProjection at the publish check snapshot.entities[id] == reconciled. publishOwnedKind
    /// chooses identities; the urlRules closure resolves captured state.publishBaseline[id] (R-M3-4a-96),
    /// sharing path (a)'s record without a new channel.
    ///
    /// Within one transaction, reread each row, project with the same helper as (a), and compare all units at
    /// millisecond precision. Clear only equal, currently flagged rows; missing baselines or unequal values
    /// write nothing. Writing clean rows would trigger needless publisher/routing refresh events each round
    /// (RR7-14).
    ///
    /// Never touch mergePartnerSyncId (CASE M-7c): only live publication applied or a quiescent singleton
    /// group clears it (§8.4.3). Clearing it here would replace a lossless partner transfer next round with an
    /// extra live rule via branch (ii).
    func clearPendingLocalEditIfUnchangedThrowing(entries: [String: RuleProjection]) async throws {
        // Empty input opens no transaction; enforce this in the primitive even though the caller also guards
        // it.
        guard !entries.isEmpty else { return }
        try await performBackgroundWriteAndWaitThrowing { context in
            try self.clearPendingLocalEditIfUnchangedBody(entries: entries, in: context)
        }
    }

    private func clearPendingLocalEditIfUnchangedBody(entries: [String: RuleProjection],
                                                      in context: ModelContext) throws {
        let index = try urlRuleTableIndex(in: context)
        // Stable order aids logs and tests; entries are independent.
        for syncId in entries.keys.sorted() {
            guard let confirmed = entries[syncId], let row = index.bySyncId[syncId] else { continue }
            guard row.pendingLocalEdit else { continue }
            let current = URLRuleKind.clearingProjection(of: Self.projectURLRule(row))
            guard URLRuleKind.clearingProjectionMatches(row: current, confirmed: confirmed) else {
                continue        // A newer user save intervened: preserve it without writes (ruling 14).
            }
            row.pendingLocalEdit = false
        }
    }

    // MARK: - Landing batch entry (R-exec-2)

    /// Apply every operation from one remote page in one write/transaction (§5.5), preserving
    /// URLRuleApplyBatch's merged order.
    ///
    /// Keep this entry here to compose shared bodies in the same context: invoking throwing wrappers would
    /// nest serialized writes and deadlock. Any throw makes performThrowing roll back the entire batch.
    ///
    /// An empty ops list with a tail hook still opens a transaction (R-M3-4a-56): M2 runs even on pages with
    /// no rule landing. Only when both are absent is there no work.
    @discardableResult
    func applyURLRuleSyncBatchThrowing(_ ops: [URLRuleSyncOp],
                                       mergeTail: URLRuleMergeTail? = nil) async throws
        -> URLRuleBatchOutcome {
        guard !ops.isEmpty || mergeTail != nil else { return URLRuleBatchOutcome() }
        return try await performBackgroundWriteAndWaitThrowing { context in
            try self.applyURLRuleSyncBatchBody(ops, mergeTail: mergeTail, in: context)
        }
    }

    /// Transaction body, extracted for readability with one caller. Five ordered stages (8b-2 extends Task 8):
    /// 1. Build one full-table syncId index including soft-deleted rows.
    /// 2. Execute preordered four-phase ops without reordering. Transfer rechecks unchanged source before
    /// writing its partner (R-M3-4a-102). Create/update/move use upsertURLRuleBody, copying remote stamps and
    /// clearing deletedDate/mergePartnerSyncId when reviving. Reorder changes only sortOrder; delete
    /// hard-deletes. These landing writes never set pendingLocalEdit.
    /// 3. Track buckets: create destination; move old bucket captured before assignment plus destination
    /// (R-M3-4a-3); reorder current bucket; delete former bucket. Content-only updates need no normalization
    /// unless creating a missing row (R-M3-4a-42(a)), reviving a soft-deleted row (§5.5), or defensively
    /// changing target. Avoid redundant publisher/push work (§6.5).
    /// 4. Evaluate URLRuleMergeTail on current projections including soft-deleted rows, execute its M2 ops,
    /// and union touched buckets (8b-2 / R-M3-4a-56). Run before normalization to close gaps left by losers.
    /// 5. Normalize live rows in each touched bucket by current (sortOrder, id), writing only changed indices
    /// (R-M3-4a-51).
    private func applyURLRuleSyncBatchBody(_ ops: [URLRuleSyncOp],
                                           mergeTail: URLRuleMergeTail?,
                                           in context: ModelContext) throws
        -> URLRuleBatchOutcome {
        var outcome = URLRuleBatchOutcome()
        var index = try urlRuleTableIndex(in: context)
        var touchedBuckets: Set<String> = []
        // R-M3-4a-102 / ruling 11: recheck source only for (α), identified by a transfer and same-identity
        // delete in this batch. (β) has only transfer and takes values from this round's inbound merged
        // entity, not the local row; applying the same check would always reject it and leave two rules.
        var alphaSources: Set<String> = []
        for op in ops {
            if case .delete(let syncId) = op { alphaSources.insert(syncId) }
        }

        /// Shared operation executor for landing and the tail hook. Both use the same transaction/index and
        /// bucket accounting, avoiding divergent implementations.
        func execute(_ op: URLRuleSyncOp) throws {
            switch op {
            case .create(let values):
                try upsertURLRuleBody(values, index: &index, in: context)
                touchedBuckets.insert(values.spaceId)
            case .update(let values):
                // Read both predicates before upsert, which immediately clears deletedDate on a revived row.
                let existing = index.bySyncId[values.syncId]
                let sourceBucket = existing?.spaceId
                // Entering a bucket means creating an absent row (R-M3-4a-42(a)) or reviving a soft-deleted
                // one (§5.5). Neither was counted among live siblings, so its incoming index may collide;
                // normalize the destination bucket (R-M3-4a-3 / RR-B9). Revival already changes deletedDate,
                // so normalization in this transaction adds no publisher event.
                let entersBucket = existing == nil || existing?.deletedDate != nil
                try upsertURLRuleBody(values, index: &index, in: context)
                if entersBucket {
                    touchedBuckets.insert(values.spaceId)
                } else if let sourceBucket, sourceBucket != values.spaceId {
                    touchedBuckets.insert(sourceBucket)
                    touchedBuckets.insert(values.spaceId)
                }
            case .move(let values):
                let sourceBucket = index.bySyncId[values.syncId]?.spaceId
                try upsertURLRuleBody(values, index: &index, in: context)
                if let sourceBucket {
                    touchedBuckets.insert(sourceBucket)
                }
                touchedBuckets.insert(values.spaceId)
            case .reorder(let syncId, _, let sortOrder):
                // Without a payload an absent row cannot be created; skip because this page has no local row
                // to reorder.
                guard let row = index.bySyncId[syncId] else { return }
                if row.sortOrder != sortOrder {
                    row.sortOrder = sortOrder
                }
                touchedBuckets.insert(row.spaceId)
            case .delete(let syncId):
                // R-M3-4a-102: a failed (α) recheck skips both transfer and same-identity delete. Phase order
                // guarantees transfer populated the deferred set first.
                guard !outcome.deferredTombstones.contains(syncId) else { return }
                if let bucket = try hardDeleteURLRuleBody(syncId: syncId, index: &index, in: context) {
                    touchedBuckets.insert(bucket)
                }
            case .transfer(let fromSyncId, let toSyncId, let source, let stamps):
                if alphaSources.contains(fromSyncId),
                   !URLRuleKind.transferSourceUnchanged(
                       row: index.bySyncId[fromSyncId].map(Self.projectURLRule), source: source) {
                    // The user changed the source after pre-pass, or it disappeared/was soft-deleted. Write
                    // neither W nor X and do not increment transferred. Return the identity for
                    // plan.parkedTombstones; reevaluate fresh values next page/round.
                    outcome.deferredTombstones.insert(fromSyncId)
                    return
                }
                let result = try transferURLRuleEditBody(toSyncId: toSyncId, source: source,
                                                         targetEffectiveStamps: stamps,
                                                         index: &index, in: context)
                if result.written > 0 { outcome.transferred += 1 }
                if result.contentSuperseded { outcome.transferSupersededByDelete += 1 }
                // A winning target unit moves W: normalize both source and destination buckets (R-M3-4a-3).
                if let movedFrom = result.movedFrom {
                    touchedBuckets.insert(movedFrom)
                    if let bucket = index.bySyncId[toSyncId]?.spaceId {
                        touchedBuckets.insert(bucket)
                    }
                }
            case .rekey(let localId, let syncId, let values):
                // §8.4.2 M1: re-key syncId first, then upsert supplied values under the new identity in the
                // same write; index.rekey already points to this row. Claiming first assigns account rank, so
                // record the destination bucket for projection, as for create.
                try rekeyURLRuleBody(localId: localId, to: syncId, index: &index, in: context)
                if let values {
                    assert(values.syncId == syncId, "url rule batch: rekey values carry another identity")
                    let sourceBucket = index.bySyncId[syncId]?.spaceId
                    try upsertURLRuleBody(values, index: &index, in: context)
                    touchedBuckets.insert(values.spaceId)
                    if let sourceBucket, sourceBucket != values.spaceId {
                        touchedBuckets.insert(sourceBucket)
                    }
                }
            // 8b-2's three §8.4.3 operations come only from the tail hook, never the initial landing batch.
            case .softDelete(let syncId, let mergePartnerSyncId):
                if let bucket = try softDeleteURLRuleBody(syncId: syncId,
                                                          mergePartnerSyncId: mergePartnerSyncId,
                                                          index: &index, in: context) {
                    touchedBuckets.insert(bucket)
                }
            case .setMergePartner(let syncId, let mergePartnerSyncId):
                // Do not record the bucket: this field affects neither routing nor order (CASE M-7 requires no
                // effects beyond its row write).
                try setURLRuleMergePartnerBody(syncId: syncId,
                                               mergePartnerSyncId: mergePartnerSyncId,
                                               index: &index, in: context)
            case .setContentGroup(let syncId, let host, let pathPrefix, let ask,
                                  let contentUpdatedDate):
                // Likewise, content changes leave bucket order and sortOrder untouched.
                try setURLRuleContentGroupBody(syncId: syncId, host: host, pathPrefix: pathPrefix,
                                               ask: ask, contentUpdatedDate: contentUpdatedDate,
                                               index: &index, in: context)
            }
        }

        // 2. Execute landing operations in order.
        for op in ops { try execute(op) }

        // 4. Run the tail hook after all landing writes and before normalization, in the same transaction
        // (R-M3-4a-56). Project current index.rows including soft-deleted rows for addressing; mergePass
        // applies the same live filter as allURLRules(). No extra read is needed, and this is R-M3-4a-100's
        // exclusion source.
        if let mergeTail {
            let result = mergeTail.evaluate(index.rows.map(Self.projectURLRule))
            for op in result.ops { try execute(op) }
            touchedBuckets.formUnion(result.touchedBuckets)
            outcome.collapsed = result.collapsed
            outcome.mergeChangedRouting = result.changedRouting
        }

        // 5. Finish with dense normalization.
        for bucket in touchedBuckets {
            let live = index.rows
                .filter { $0.spaceId == bucket && $0.deletedDate == nil }
                .sorted { ($0.sortOrder, $0.id) < ($1.sortOrder, $1.id) }
            for (position, row) in live.enumerated() where row.sortOrder != position {
                row.sortOrder = position
            }
        }
        return outcome
    }

    /// Value snapshot inside the transaction, never model objects (see PhiLocalURLRule). Matches
    /// AccountPhiURLRuleAccess.project, but reads the write index after this page's landing mutations instead
    /// of a main-context fetch.
    private static func projectURLRule(_ model: SpaceURLRule) -> PhiLocalURLRule {
        PhiLocalURLRule(id: model.id,
                        syncId: model.syncId,
                        spaceId: model.spaceId,
                        host: model.host,
                        pathPrefix: model.pathPrefix,
                        askBeforeRouting: model.askBeforeRouting,
                        sortOrder: model.sortOrder,
                        createdDate: model.createdDate,
                        contentUpdatedDate: model.contentUpdatedDate,
                        targetUpdatedDate: model.targetUpdatedDate,
                        deletedDate: model.deletedDate,
                        pendingLocalEdit: model.pendingLocalEdit,
                        mergePartnerSyncId: model.mergePartnerSyncId)
    }

    /// Nine-field payload wrapper forwarding to the individual-argument body above.
    @discardableResult
    private func upsertURLRuleBody(_ values: URLRuleLandingValues,
                                   index: inout URLRuleTableIndex,
                                   in context: ModelContext) throws -> SpaceURLRule {
        try upsertURLRuleBody(syncId: values.syncId,
                              spaceId: values.spaceId,
                              host: values.host,
                              pathPrefix: values.pathPrefix,
                              ask: values.askBeforeRouting,
                              sortOrder: values.sortOrder,
                              createdDate: values.createdDate,
                              contentUpdatedDate: values.contentUpdatedDate,
                              targetUpdatedDate: values.targetUpdatedDate,
                              index: &index,
                              in: context)
    }

    @MainActor
    func urlRulesPublisher() -> AnyPublisher<[SpaceRoutingRule], Never> {
        guard mainContext != nil else {
            return Just([]).eraseToAnyPublisher()
        }

        let subject = CurrentValueSubject<[SpaceRoutingRule], Never>([])
        let fetch = { self.getAllURLRules() }
        subject.send(fetch())

        let cancellable = NotificationCenter.default
            .publisher(for: .NSManagedObjectContextDidSave)
            .filter {
                Self.notificationContainsChanges(
                    $0,
                    matching: { $0.entity.name == SpaceURLRule.entityName }
                )
            }
            .receive(on: DispatchQueue.main)
            .sink { _ in subject.send(fetch()) }

        return subject
            .removeDuplicates()
            .handleEvents(receiveCancel: { cancellable.cancel() })
            .prefix(untilOutputFrom: NotificationCenter.default.publisher(
                for: Self.willCloseNotification, object: self))
            .eraseToAnyPublisher()
    }

    // MARK: - Normalization (§8.1 fixed-point function)

    // Internal static methods on LocalStore; §8.1 introduces no namespace. Called for local edits
    // (URLRuleDraft.ContentUnit.init), inbound planning (URLRuleKind, Task 7), and landing
    // (applyURLRuleEditsBody/upsertURLRuleBody).

    /// Idempotent: normalizedRule(normalizedRule(x)) == normalizedRule(x). Proof in §8.1; CASE U-6.
    static func normalizedRule(host: String, pathPrefix: String?)
        -> (host: String, pathPrefix: String?) {
        (host: normalizedHost(host), pathPrefix: normalizedPathPrefix(pathPrefix))
    }

    /// Host normalization (R-M3-4a-21 / §8.1). Scan the right edge once with one character set: separate
    /// dot-stripping and whitespace-trimming passes are not fixed points for alternating suffixes, and
    /// repeated passes need an unjustified bound.
    static func normalizedHost(_ raw: String) -> String {
        var s = Substring(raw).drop(while: { $0.isWhitespace || $0.isNewline })
        while let last = s.last, last.isWhitespace || last.isNewline || last == "." {
            s = s.dropLast()
        }
        return String(s).lowercased()
    }

    /// Path normalization (R-M3-4a-21 / §8.1). Preserve step order: stripping trailing slashes before decoding
    /// lets re-encoding restore them because slash is urlPathAllowed. Then /foo%2F normalizes to /foo/ while
    /// /foo/ becomes /foo; worse, /%2F becomes // then nil, silently broadening the rule. Slash and nil
    /// differ: nil matches any path, slash only the root (URLRouter.swift:80-86; phi_url_router.cc:64-78).
    ///
    /// Both the Swift URLRouter and C++ phi::PhiURLRouter compare against the percent-encoded canonical path,
    /// so stored prefixes must use that form regardless of user input.
    static func normalizedPathPrefix(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "/" { return "/" }                                          // 0
        guard !trimmed.isEmpty else { return nil }                                // 1
        var s = trimmed.hasPrefix("/") ? trimmed : "/" + trimmed                  // 2
        s = s.removingPercentEncoding ?? s                                        // 3
        s = s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? s  // 4
        while s.count > 1 && s.hasSuffix("/") { s.removeLast() }                  // 5
        return s                                                                  // 6
    }
}

extension LocalStore.URLRuleDraft {
    /// Flat convenience initializer supplying content and spaceId for Task 11's four construction sites and
    /// the agent router (SpaceURLRulesEditor.swift:143-149; AgentSpaceRouter+Management.swift:247-252,
    /// 308-311, 350-353). Nil spaceId supports older callers whose SpaceManager.setAllRules/setRules supplies
    /// the target. Field-dirty callers (M5 / 8b-4) use memberwise initialization directly.
    init(id: String = UUID().uuidString,
         host: String,
         pathPrefix: String? = nil,
         askBeforeRouting: Bool = false,
         spaceId: String? = nil,
         sortOrder: Int? = nil,
         createdDate: Date? = nil,
         syncId: String? = nil,
         contentUpdatedDate: Date? = nil) {
        self.init(id: id,
                  syncId: syncId,
                  content: ContentUnit(host: host,
                                       pathPrefix: pathPrefix,
                                       askBeforeRouting: askBeforeRouting),
                  spaceId: spaceId,
                  sortOrder: sortOrder,
                  createdDate: createdDate,
                  contentUpdatedDate: contentUpdatedDate)
    }
}

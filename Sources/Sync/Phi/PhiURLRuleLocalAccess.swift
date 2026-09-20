// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

/// Value snapshot of a local rule, never a model object: SwiftData mutates instances in place, swallowing
/// object-based change detection (LocalStore+Space.swift:431-452; LocalStore.swift:536-540). Like
/// PhiLocalBookmark, this Sync/Phi type is independent of LocalStorage for SwiftData-free tests. Task 8 adds
/// access protocol/production implementation in the same file, following M3-3 PR2's value-type-first layout.
struct PhiLocalURLRule: Equatable {
    /// Physical local row ID (SpaceURLRule.id), used to address landing operations.
    var id: String
    /// Lowercase account UUID (SpaceURLRule.syncId), minted at insertion (R-M3-4a-23) and effectively nonnil
    /// for live rows. Optional supports legacy pre-V11 rows before backfill.
    var syncId: String?
    /// Local target Space ID; Incognito uses the bare SpaceManager.incognitoRuleTargetId prefix.
    var spaceId: String
    var host: String
    /// nil matches any path (empty string on wire); slash matches only root. These are distinct values (§8.1).
    var pathPrefix: String?
    var askBeforeRouting: Bool
    /// Dense bucket index (§8.3), projected from wire rank by URLRuleKind.rankToSortOrder.
    var sortOrder: Int
    var createdDate: Date
    /// nil means content group never edited; baseline-free projection falls back to createdDate (R-M3-4a-12).
    var contentUpdatedDate: Date?
    /// Baseline-free §8.2 projection uses targetUpdatedDate ?? createdDate (R-M3-4a-73).
    var targetUpdatedDate: Date?
    /// Soft-delete marker (R-M3-4a-41), distinguishing deleted rows returned by allURLRulesIncludingDeleted.
    var deletedDate: Date?
    /// User-edit signal (R-M3-4a-65). The Task 7 kind adapter never reads it; exactly two reader sites belong
    /// to 8b-1/8b-3.
    var pendingLocalEdit: Bool
    /// Merge partner (R-M3-4a-71), local-only state excluded from wire entity/signature. The kind adapter
    /// neither reads nor writes it.
    var mergePartnerSyncId: String?
}

// MARK: - Landing values (§5.5 single merged write)

/// Complete values for one merged row landing (§5.5). These nine fields are the only payload columns. Exclude
/// deletedDate/pendingLocalEdit/mergePartnerSyncId: landing never changes pendingLocalEdit (§8.4.5's two
/// clearing sites are in publication), and the batch handles the other two through §5.5 existing-row rules. Do
/// not reuse PhiLocalURLRule with local ID/state columns, which would allow accidental unauthorized writes to
/// compile.
struct URLRuleLandingValues: Equatable, Sendable {
    var syncId: String
    var spaceId: String
    var host: String
    var pathPrefix: String?
    var askBeforeRouting: Bool
    /// Final dense page index, computed above this protocol from rank/identity (§8.3), like bookmark
    /// rankToIndex (R-exec-2). Batch storage only performs final densification.
    var sortOrder: Int
    /// Payload created_at_ms (R-M3-4a-20).
    var createdDate: Date
    /// Merged content-group timestamp (R-M3-4a-20 / R-M3-4a-48), never now: the engine does not mint stamps.
    var contentUpdatedDate: Date
    /// Merged target timestamp, likewise copied rather than minted.
    var targetUpdatedDate: Date
}

/// One local write for a remote rule landing.
enum URLRuleSyncOp: Equatable, Sendable {
    /// Create from payload if absent even in the soft-deleted-inclusive domain (R-M3-4a-42(a)).
    case create(URLRuleLandingValues)
    /// Update content and both remote stamps in place without changing buckets.
    case update(URLRuleLandingValues)
    /// Rehome target with content and both remote stamps in one write; normalize both source and destination
    /// buckets (R-M3-4a-3).
    case move(URLRuleLandingValues)
    /// Pure reorder writes only sortOrder and normalizes this bucket, preserving spaceId and both timestamps.
    case reorder(syncId: String, spaceId: String, sortOrder: Int)
    /// Inbound tombstones hard-delete (R-M3-4a-41).
    case delete(syncId: String)
    /// §8.4.2 claim landing resolves by local ID from context.pairs, which OwnedItemApplyStep lacks. Non-nil
    /// values means adoptedFieldWrites includes this identity: re-key and merged fields share one row write
    /// (R-M3-4a-42(b), at most one landing write per identity/page).
    case rekey(localId: String, to: String, values: URLRuleLandingValues?)

    // MARK: 8b-2 M2 operations (§8.4.3), produced only by URLRuleMergeTail. These local convergence writes
    // bypass URLRuleApplyBatch's remote-landing coalescing/downgrades.

    /// Soft-delete the loser (§8.4.3 step 2(b)), writing deletedDate and mergePartnerSyncId together (RR8-4).
    /// Editor deletion supplies nil partner. Preserve pendingLocalEdit.
    case softDelete(syncId: String, mergePartnerSyncId: String?)
    /// §8.4.3 step 1 writes only the partner hint; nil clears it through either clearing rule.
    case setMergePartner(syncId: String, mergePartnerSyncId: String?)
    /// §8.4.3 step 2(a) winner absorption writes the three content fields and their shared stamp. Preserve
    /// sortOrder, targetUpdatedDate, deletedDate and pendingLocalEdit.
    case setContentGroup(syncId: String, host: String, pathPrefix: String?,
                         ask: Bool, contentUpdatedDate: Date)

    // MARK: 8b-3 edit transfer (§8.4.4), phase 3 after update and before delete (R-M3-4a-93).

    /// M3 transfers unpublished user intent from fromSyncId to toSyncId via LWW merge units, writing only
    /// whole winning groups. R-M3-4a-102 adds source identity for transaction-level reread/comparison against
    /// source. Recheck only (α), identified by same-identity delete in this batch; (β) has only transfer and
    /// uses inbound merged values, not the local source row, so local comparison would reject it forever.
    /// targetEffectiveStamps comes from URLRuleApplyBatch.accountStamps (R-M3-4a-98); missing account stamps
    /// fall back to row stamps.
    case transfer(fromSyncId: String, toSyncId: String,
                  source: RuleProjection, targetEffectiveStamps: URLRuleEffectiveStamps)

    /// Account identity targeted by this operation: rekey's new identity, or transfer's destination.
    var syncId: String {
        switch self {
        case .create(let values), .update(let values), .move(let values):
            return values.syncId
        case .reorder(let syncId, _, _), .delete(let syncId):
            return syncId
        case .rekey(_, let to, _):
            return to
        case .softDelete(let syncId, _), .setMergePartner(let syncId, _):
            return syncId
        case .setContentGroup(let syncId, _, _, _, _):
            return syncId
        case .transfer(_, let toSyncId, _, _):
            return toSyncId
        }
    }
}

// MARK: - Landing tail (R-M3-4a-56 / plan ruling 3)

/// Evaluate current row projections including soft-deleted rows after all landing writes and before dense
/// normalization in the same transaction (R-M3-4a-56). Purely produce M2 ops/buckets only for actual
/// duplicates (§8.4.3). Reuse this projection for R-M3-4a-100's second candidate exclusion of
/// edited/deleted/missing rows, with no extra read (plan ruling 6(3)).
///
/// The closure must not have a global actor: it runs on the write queue. Construct in a nonisolated factory
/// capturing value types to avoid inferred MainActor isolation.
struct URLRuleMergeTail {
    var evaluate: ([PhiLocalURLRule]) -> URLRuleMergeResult
}

/// Observable landing outcome. collapsed counts only actually soft-deleted losers (R-M3-4a-54).
struct URLRuleBatchOutcome: Sendable, Equatable {
    var collapsed = 0
    /// §6.6 row 8 triggers only when M2 changes soft deletion or content. Pointer-only writes do not affect
    /// routing and must cause zero refreshes (CASE M-7).
    var mergeChangedRouting = false
    /// R-M3-4a-102 / 8b-3 ruling 11: when transaction reread finds (α)'s source changed, absent or
    /// soft-deleted, skip both transfer and same-identity delete. The executor records these identities; M2
    /// never does. Engine parks them via pendingTombstone without changing rows, never counts them
    /// landed/deleted. Always empty for bookmarks/pins.
    var deferredTombstones: Set<String> = []
    /// §13.2 transferred counts transfer operations that actually wrote at least one unit (8b-3 / ruling 9).
    /// Zero-unit transfers neither count nor set pendingLocalEdit (§8.4.5).
    var transferred = 0
    /// §13.3 counts transfer content groups that lost as superseded_by_delete. Evaluate inside the transaction
    /// using max(W row stamp, effective account stamp) (R-M3-4a-98), not in plan, which lacks post-update W
    /// and account-stamp table. CASE M-34 (b)/(c) pin both requirements.
    var transferSupersededByDelete = 0
}

/// All rule operations for one remote page, coalesced and ordered by §5.5. A list, not a single operation, is
/// required for one all-or-nothing page transaction.
struct URLRuleApplyBatch {
    private(set) var ops: [URLRuleSyncOp]
    /// R-M3-4a-56 tail hook (8b-2). Nil skips M2 for this page; existing Task 8/bookmark/pin paths omit it.
    private(set) var mergeTail: URLRuleMergeTail?
    /// R-M3-4a-98 target stamps for transfer, computed by effectiveAccountStamps before constructing the
    /// batch. This stage supplies them to the 8b-3 executor.
    private(set) var accountStamps: [String: URLRuleEffectiveStamps]

    /// currentSpaceIds maps syncId to current local Space from this page's allURLRulesIncludingDeleted read.
    /// Coalesce same-identity steps (R-M3-4a-42(b) / RR-B9): move and update carry the same merged payload;
    /// keep move if target changed, otherwise update. Separate writes could reassign after normalization into
    /// an unnormalized bucket.
    ///
    /// Downgrade a move-only unchanged target to reorder (CASE U-10b), avoiding unnecessary rehome
    /// normalization. Preserve stable first-identity order within phases: ordinary landing writes → transfer →
    /// delete (R-M3-4a-93). Transfers compare W after this page's update (CASE M-34), yet run before deleting
    /// source X. M2 passthrough operations share this pre-delete window independently.
    init(unordered: [URLRuleSyncOp], currentSpaceIds: [String: String] = [:],
         mergeTail: URLRuleMergeTail? = nil,
         accountStamps: [String: URLRuleEffectiveStamps] = [:]) {
        self.mergeTail = mergeTail
        self.accountStamps = accountStamps
        // One slot per identity in first-occurrence order. Later duplicate operation types replace earlier
        // ones carrying the same merged result.
        struct Slot {
            var create: URLRuleLandingValues?
            var update: URLRuleLandingValues?
            var move: URLRuleLandingValues?
            var reorder: (spaceId: String, sortOrder: Int)?
            var delete = false
            /// §8.4.2 M1 local row to receive this identity.
            var rekey: (localId: String, values: URLRuleLandingValues?)?
        }
        var order: [String] = []
        var slots: [String: Slot] = [:]
        // Claim each local row at most once per page (RR3-4 / CASE M-13). Planner pairing is one-to-one;
        // defensively keep only the first rekey for a row. Later identities fail validation, park, then create
        // next round. Never let a second rekey evict the first identity and trigger its tombstone.
        var rekeyedLocalIds: Set<String> = []
        // M2 operations bypass slots and move downgrades: they are local convergence writes, not coalescible
        // remote landings. Preserve order before delete so §8.4.3 step 2(b) can see rows hard-deleted later in
        // the page.
        var passthrough: [URLRuleSyncOp] = []
        // Transfers also bypass slots/move downgrades: they write a partner identity rather than the source's
        // landing record, and occupy their own phase.
        var transfers: [URLRuleSyncOp] = []
        for op in unordered {
            switch op {
            case .softDelete, .setMergePartner, .setContentGroup:
                passthrough.append(op)
                continue
            case .transfer:
                transfers.append(op)
                continue
            case .create, .update, .move, .reorder, .delete, .rekey:
                break
            }
            let syncId = op.syncId
            if case .rekey(let localId, _, _) = op {
                guard rekeyedLocalIds.insert(localId).inserted else {
                    assertionFailure("url rule batch: local row claimed twice in one page")
                    continue
                }
            }
            if slots[syncId] == nil {
                slots[syncId] = Slot()
                order.append(syncId)
            }
            switch op {
            case .create(let values): slots[syncId]?.create = values
            case .update(let values): slots[syncId]?.update = values
            case .move(let values): slots[syncId]?.move = values
            case .reorder(_, let spaceId, let sortOrder): slots[syncId]?.reorder = (spaceId, sortOrder)
            case .delete: slots[syncId]?.delete = true
            case .rekey(let localId, _, let values): slots[syncId]?.rekey = (localId, values)
            case .softDelete, .setMergePartner, .setContentGroup, .transfer: continue   // Already handled above.
            }
        }

        var upgrades: [URLRuleSyncOp] = []
        var deletes: [URLRuleSyncOp] = []
        for syncId in order {
            guard let slot = slots[syncId] else { continue }
            var merged: URLRuleSyncOp?
            if let rekey = slot.rekey {
                // §8.4.2 M1 / R-M3-4a-42(b): combine claim and adoptedFieldWrites update into one rekey
                // operation. Claim signatures include target, so claiming cannot also rehome; move/create
                // values are defensive fallbacks.
                merged = .rekey(localId: rekey.localId, to: syncId,
                                values: rekey.values ?? slot.update ?? slot.move ?? slot.create)
            } else if let move = slot.move {
                if currentSpaceIds[syncId] == move.spaceId {
                    // Target unchanged: keep update when content changes, create for an absent row, otherwise
                    // pure reorder. Create/update share upsert but differ in bucket accounting.
                    if let update = slot.update {
                        merged = .update(update)
                    } else if let create = slot.create {
                        merged = .create(create)
                    } else {
                        merged = .reorder(syncId: syncId, spaceId: move.spaceId, sortOrder: move.sortOrder)
                    }
                } else {
                    // Changed or unknown target means rehome. Move carries complete content and new spaceId,
                    // preserving every update value.
                    merged = .move(move)
                }
            } else if let create = slot.create {
                merged = .create(create)
            } else if let update = slot.update {
                merged = .update(update)
            } else if let reorder = slot.reorder {
                merged = .reorder(syncId: syncId, spaceId: reorder.spaceId, sortOrder: reorder.sortOrder)
            }
            if slot.delete {
                // An identity should not have both an upgrade and delete. §8.4.4 (α)'s transfer/delete pair
                // bypasses this check because transfer never enters a slot and writes W. If collision occurs,
                // final delete still gives deterministic state.
                assert(merged == nil, "url rule batch: identity \(syncId.prefix(8)) has both an upgrade and a delete")
                deletes.append(.delete(syncId: syncId))
            }
            if let merged {
                upgrades.append(merged)
            }
        }
        ops = upgrades + transfers + passthrough + deletes
    }
}

// MARK: - Access protocol

/// Sole engine/local-rule boundary, using main-actor hops like PhiSpaceLocalAccess. Appendix C-4 owns member
/// allocation; update protocol, production and fake together. Task 6 owns routing refresh; Task 9
/// hard-delete/purge; 8b-1 signature/pending/unpublished/partner queries and projection notes; 8b-3
/// partnerNotAtRest; 8b-4 both flag-clearing APIs. AccountPhiURLRuleAccess below is production.
@MainActor
protocol PhiURLRuleLocalAccess: AnyObject {
    /// All live account rules, ordered by spaceId/sortOrder/id. One fetch per page, not a round-start frozen
    /// snapshot; reread after each landing commit (R-M3-4a-62), then reuse for projection/convergence/landing.
    /// Exclude soft-deleted rows from dense ordering/routing (R-M3-4a-51). Throw on failure (R-exec-3), never
    /// return [] that would tombstone all account rules.
    func allURLRules() throws -> [PhiLocalURLRule]

    /// Snapshot/diff domain includes live and soft-deleted rows (R-M3-4a-51). Diff needs deletion intent to
    /// emit tombstones (§5.7); normalization excludes them. Reuse the same fetch without the live filter.
    func allURLRulesIncludingDeleted() throws -> [PhiLocalURLRule]

    /// All live siblings in a target bucket without sync-eligibility filtering, for §8.3 ordering. Read this
    /// page's cached allURLRules group, never fetch again.
    func siblings(inSpaceId spaceId: String) -> [PhiLocalURLRule]

    /// Independent predicate from the allURLRules domain, keyed by syncId rather than local ID.
    func isKnownLocalURLRule(_ syncId: String) -> Bool

    /// Sole local read for §9.3 cascade (R-M3-4a-36 / R-exec-11 identity-level equivalent). Return candidate
    /// identities still claimed by live rows from the full-store read, not the filtered snapshot (R-exec-4 /
    /// R-exec-8). Throw skips this kind's cascade (R-exec-3). Production fills claimed only; the registration
    /// closure adds owners with OwnedOwnerMaps because access has no resolver.
    func liveOwners(_ candidates: Set<String>) throws -> OwnedLiveRows

    /// Apply a whole page in one transaction (§5.5); failure forbids baselines. Return tail-hook
    /// collapsed/routing-change outcome from that same transaction (§6.6 row 8). Empty ops with a tail still
    /// opens a convergence transaction (R-M3-4a-56). Discardable result preserves Task 8 value fixtures;
    /// engine landURLRules always consumes it.
    @discardableResult
    func apply(_ batch: URLRuleApplyBatch) async throws -> URLRuleBatchOutcome

    /// After page commit, refresh Chromium routing once (§6.6 / R-M3-4a-34) via
    /// SpaceManager.reloadURLRulesFromStore. Keep this side effect on access rather than direct
    /// engine-to-manager coupling, like Space landing effects (Task 6 ruling 1).
    func refreshRoutingTableAfterLanding()

    /// §5.7 exit 1: accepted tombstone hard-deletes its local soft-deleted row. Already absent after
    /// concurrent cleanup is a successful no-op.
    func hardDeleteURLRule(syncId: String) async throws
    /// §5.7 exit 2: hard-delete rows with deletedDate < cutoff and return count. Retention uses the row
    /// timestamp, never cursors.
    func purgeSoftDeletedURLRules(olderThan cutoff: Date) async throws -> Int

    // MARK: D30（8b-1）

    /// Build §8.4.1 signature index once from this page's full read minus soft-deleted rows (R-M3-4a-62 /
    /// RR4-3). Group arrays permit duplicates; sort each by syncId then local ID for first-candidate
    /// one-to-one claiming (§8.4.2). In-memory indexing avoids extra fetches and one main-actor hop per
    /// entity.
    func signatureIndex(resolve: OwnerResolver) -> [RuleSignature: [PhiLocalURLRule]]

    /// R-M3-4a-73 input: identities satisfying (α)'s first three conditions (row exists, live, signature
    /// available) plus pendingLocalEdit. Populate 8b-3 OwnedItemPlanContext.pendingLocalEdits.
    func pendingLocalEditIdentities(resolve: OwnerResolver) -> Set<String>

    /// Same domain, with server and reconciled present but unequal, matching publishOwnedKind's pending set.
    func unpublishedIdentities(table: PhiOwnedItemTable, resolve: OwnerResolver) -> Set<String>

    /// Resolve identity → quiescent partner W by §8.4.4's three steps: use a quiescent pointer target;
    /// otherwise find a quiescent live row matching X's baseline signature, choosing smallest syncId;
    /// otherwise omit. W must satisfy all ten quiescence conditions, including this page's tombstones
    /// (R-M3-4a-86), and cannot equal X (RR7-13). X's domain includes soft-deleted rows for (β), not just
    /// (α)'s live conditions (RR8-1). Only 8b-3 α/β consume it; 8b-1 defines/tests it.
    func mergePartners(table: PhiOwnedItemTable, resolve: OwnerResolver,
                       tombstonesThisPage: Set<String>) -> [String: String]

    /// R-M3-4a-62 projection update immediately after claim persistence. Map local row ID → new syncId,
    /// deliberately opposite bookmark notePersistedClaims (§5.6). Otherwise the same page could still see the
    /// old identity and claim a second identity onto the same row.
    func notePersistedClaims(_ claimed: [String: String])

    /// Remove actually deleted identities from this page's projection immediately (R-M3-4a-62), like
    /// bookmarks. Yielded identities never enter this set (R-M3-4a-61).
    func noteDeletedRows(_ syncIds: Set<String>)

    // MARK: D30（8b-3）

    /// Identities with a real partner row but no quiescent W after the three-step search (§5.6 / R-M3-4a-73 /
    /// RR10-3). Distinguish this from no partner; otherwise ii/A9 could create a second divergent rule.
    ///
    /// One pure protocol-extension implementation is shared by production/fake (RR12-2). Plan passes this
    /// page's full rows and tombstones; publication passes round-end full rows and empty page tombstones.
    /// Never use live-only allURLRules: β's X is soft-deleted and would vanish, disabling the guard
    /// (R-M3-4a-51).
    func partnerNotAtRest(table: PhiOwnedItemTable, rows: [PhiLocalURLRule],
                          resolve: OwnerResolver,
                          tombstonesThisPage: Set<String>) -> Set<String>

    // MARK: D30 (8b-4): §8.4.5's two flag-clearing paths

    /// Path (a): clear pendingLocalEdit only if every current merge unit equals confirmed at millisecond
    /// precision. Clear mergePartnerSyncId regardless of comparison, in the same row write (§8.4.3 lifecycle
    /// row 2). Return whether the flag cleared; unresolved/unprojectable rows return false without writes.
    @discardableResult
    func clearPendingLocalEdit(syncId: String,
                               ifProjectionEquals confirmed: RuleProjection) async throws -> Bool

    /// Path (b): entries maps candidates to row projections captured at publication decision time
    /// (R-M3-4a-91). Reread/project/compare within one transaction using path (a)'s helper; clear only equal
    /// flags and never touch mergePartnerSyncId.
    func clearPendingLocalEditIfUnchanged(entries: [String: RuleProjection]) async throws

    // Do not add clearAllSyncIds (§4.4 final paragraph / R-M3-4a-23). Rule IDs minted at insertion must
    // survive self-revocation or prior account identities become orphaned. Its absence is the guard;
    // coordinator clearing includes bookmarks only.
}

// MARK: - Sole partnerNotAtRest implementation (8b-3 / controller ruling)

extension PhiURLRuleLocalAccess {
    /// RR10-7 search: a quiescent live pointer target is W; otherwise search baseline-signature matches for a
    /// quiescent live W. Both steps share URLRuleSignatureQueries.mergePartners so winner selection cannot
    /// diverge. If neither finds W, include X only when a live pointer target or another live fallback-group
    /// row exists, parking for retry; no partner uses ii/A9 behavior.
    ///
    /// Always try fallback when the pointer target is non-quiescent: a live anchor can permanently lose
    /// signature eligibility after its Space hides, otherwise parking lasts until 30-day cleanup (§8.4.7). The
    /// issue is no canonical record in the group, not one bad pointer. Soft-deleted partners do not count,
    /// since quiescence condition 7 would exclude them forever.
    func partnerNotAtRest(table: PhiOwnedItemTable, rows: [PhiLocalURLRule],
                          resolve: OwnerResolver,
                          tombstonesThisPage: Set<String>) -> Set<String> {
        let normalize = URLRuleSignatureQueries.normalize
        let partners = URLRuleSignatureQueries.mergePartners(
            rows: rows, table: table, resolve: resolve,
            tombstonesThisPage: tombstonesThisPage)
        // Index live rows by identity and current signature; fallback asks whether another live group member
        // exists.
        var liveBySyncId: [String: PhiLocalURLRule] = [:]
        var liveBySignature: [RuleSignature: [String]] = [:]
        for row in rows where row.deletedDate == nil {
            guard let syncId = row.syncId else { continue }
            liveBySyncId[syncId] = row
            guard let signature = URLRuleKind.signature(of: row, resolve: resolve,
                                                        normalize: normalize) else { continue }
            liveBySignature[signature, default: []].append(syncId)
        }
        var out: Set<String> = []
        // X includes soft-deleted rows for β (RR8-1).
        for row in rows {
            guard let identity = row.syncId, partners[identity] == nil else { continue }
            var hasPartnerRow = false
            if let pointer = row.mergePartnerSyncId, pointer != identity,
               liveBySyncId[pointer] != nil {
                hasPartnerRow = true
            }
            if !hasPartnerRow,
               let baseline = URLRuleKind.baselineSignature(identity: identity, table: table,
                                                            resolve: resolve, normalize: normalize),
               liveBySignature[baseline]?.contains(where: { $0 != identity }) == true {
                hasPartnerRow = true
            }
            if hasPartnerRow { out.insert(identity) }
        }
        return out
    }
}

// MARK: - Four D30 read-only queries shared by production and fake

/// Pure signatureIndex/pendingLocalEditIdentities/unpublishedIdentities/mergePartners queries over this page's
/// full rows including soft-deleted entries. Each applies its own domain filter. Production supplies
/// cachedRows, fake supplies rows; one predicate avoids divergent quiescence definitions (§8.4.1).
enum URLRuleSignatureQueries {
    /// §8.4.1 normalization function, one of three call sites, injected as for normalizeArrivals.
    static let normalize: (String, String?) -> (host: String, pathPrefix: String?) = {
        LocalStore.normalizedRule(host: $0, pathPrefix: $1)
    }

    static func signatureIndex(rows: [PhiLocalURLRule],
                               resolve: OwnerResolver) -> [RuleSignature: [PhiLocalURLRule]] {
        var out: [RuleSignature: [PhiLocalURLRule]] = [:]
        for row in rows where row.deletedDate == nil {
            guard let signature = URLRuleKind.signature(of: row, resolve: resolve,
                                                        normalize: normalize) else { continue }
            out[signature, default: []].append(row)
        }
        for key in out.keys {
            out[key]?.sort { ($0.syncId ?? "", $0.id) < ($1.syncId ?? "", $1.id) }
        }
        return out
    }

    static func pendingLocalEditIdentities(rows: [PhiLocalURLRule],
                                           resolve: OwnerResolver) -> Set<String> {
        var out: Set<String> = []
        for row in rows where row.deletedDate == nil && row.pendingLocalEdit {
            guard let syncId = row.syncId,
                  URLRuleKind.signature(of: row, resolve: resolve, normalize: normalize) != nil
            else { continue }
            out.insert(syncId)
        }
        return out
    }

    static func unpublishedIdentities(rows: [PhiLocalURLRule], table: PhiOwnedItemTable,
                                      resolve: OwnerResolver) -> Set<String> {
        var out: Set<String> = []
        for row in rows where row.deletedDate == nil {
            guard let syncId = row.syncId, let cursor = table.cursors[syncId],
                  let server = cursor.server, let reconciled = cursor.reconciled,
                  server != reconciled,
                  URLRuleKind.signature(of: row, resolve: resolve, normalize: normalize) != nil
            else { continue }
            out.insert(syncId)
        }
        return out
    }

    static func mergePartners(rows: [PhiLocalURLRule], table: PhiOwnedItemTable,
                              resolve: OwnerResolver,
                              tombstonesThisPage: Set<String>) -> [String: String] {
        func atRest(_ row: PhiLocalURLRule) -> Bool {
            URLRuleKind.isAtRest(row: row, cursor: row.syncId.flatMap { table.cursors[$0] },
                                 resolve: resolve, normalize: normalize,
                                 tombstonesThisPage: tombstonesThisPage)
        }
        // Candidate W rows are quiescent and live. Group by current signature and sort by syncId for the
        // fallback minimum.
        var restingBySyncId: [String: PhiLocalURLRule] = [:]
        var restingBySignature: [RuleSignature: [PhiLocalURLRule]] = [:]
        for row in rows where row.deletedDate == nil {
            guard let syncId = row.syncId, atRest(row),
                  let signature = URLRuleKind.signature(of: row, resolve: resolve,
                                                        normalize: normalize) else { continue }
            restingBySyncId[syncId] = row
            restingBySignature[signature, default: []].append(row)
        }
        for key in restingBySignature.keys {
            restingBySignature[key]?.sort { ($0.syncId ?? "") < ($1.syncId ?? "") }
        }
        var out: [String: String] = [:]
        // X includes soft-deleted rows (RR8-1).
        for x in rows {
            guard let xId = x.syncId else { continue }
            // 1. The mergePartnerSyncId target must exist, be quiescent, and differ from X.
            if let pointer = x.mergePartnerSyncId, pointer != xId, restingBySyncId[pointer] != nil {
                out[xId] = pointer
                continue
            }
            // 2. Fallback: choose the smallest syncId among quiescent live rows matching baselineSignature(X).
            guard let baseline = URLRuleKind.baselineSignature(identity: xId, table: table,
                                                               resolve: resolve, normalize: normalize),
                  let partner = restingBySignature[baseline]?.first(where: { $0.syncId != xId }),
                  let partnerId = partner.syncId else { continue }
            out[xId] = partnerId
            // 3. If neither yields a candidate, omit X from this table (the guard above).
        }
        return out
    }
}

// MARK: - Production implementation

/// Production implementation, parallel to AccountPhiPinnedTabAccess in PhiPinnedTabLocalAccess.swift.
/// Initialize with LocalStore, not Account: AccountPhiBookmarkAccess(account:) lazily reaches the real user
/// directory through account.localStorage, preventing production-class tests. Accepting LocalStore lets CASE
/// U-10 / U-10f / U-16 / U-26 run against a real temporary store. buildPhiSyncEngine already has
/// account.localStorage, so production behavior is unchanged.
@MainActor
final class AccountPhiURLRuleAccess: PhiURLRuleLocalAccess {
    private let store: LocalStore
    /// Projection from this page's single fetch. allURLRules() / allURLRulesIncludingDeleted() rebuild it;
    /// siblings(inSpaceId:) and isKnownLocalURLRule(_:) reuse it without another fetch.
    private var cachedRows: [PhiLocalURLRule] = []          // Includes soft-deleted rows.
    private var cachedLive: [PhiLocalURLRule] = []          // Excludes soft-deleted rows.
    private var cachedSiblings: [String: [PhiLocalURLRule]] = [:]
    private var cachedLiveSyncIds: Set<String> = []
    /// Distinguish a loaded empty snapshot from a missing snapshot. Otherwise the two nonthrowing readers
    /// silently report every row absent, causing the engine to treat every identity as a dead mapping.
    private var snapshotIsLoaded = false

    init(store: LocalStore) {
        self.store = store
    }

    // MARK: - Reads

    func allURLRules() throws -> [PhiLocalURLRule] {
        try rebuildCache()
        return cachedLive
    }

    func allURLRulesIncludingDeleted() throws -> [PhiLocalURLRule] {
        try rebuildCache()
        return cachedRows
    }

    func siblings(inSpaceId spaceId: String) -> [PhiLocalURLRule] {
        guard requireLoadedSnapshot() else { return [] }
        return cachedSiblings[spaceId] ?? []
    }

    func isKnownLocalURLRule(_ syncId: String) -> Bool {
        guard requireLoadedSnapshot() else { return false }
        return cachedLiveSyncIds.contains(syncId)
    }

    /// Fetch independently without reading or replacing the page cache. Retention cascades run at most once
    /// per round, at its end; replacing the cache would violate R-M3-4a-62's per-page landing snapshot. Read
    /// failures throw (R-exec-3).
    func liveOwners(_ candidates: Set<String>) throws -> OwnedLiveRows {
        guard let context = store.getMainContext() else {
            AppLogError("[phi-sync] url rule live-owner read failed: no main context")
            throw LocalStoreWriteError.storeUnavailable
        }
        let models: [SpaceURLRule]
        do {
            models = try store.allURLRuleModelsIncludingDeleted(in: context)
        } catch {
            // R12: log only the type and domain/code, never row contents.
            AppLogError("[phi-sync] url rule live-owner fetch failed: \(PhiSyncLog.describe(error))")
            throw error
        }
        var claimed: Set<String> = []
        for model in models where model.deletedDate == nil {
            if let syncId = model.syncId, candidates.contains(syncId) {
                claimed.insert(syncId)
            }
        }
        return OwnedLiveRows(claimed: claimed, owners: [:])
    }

    // MARK: - Writes

    /// Delegate transactions, ordered execution, and dense reordering of both buckets to
    /// LocalStore.applyURLRuleSyncBatchThrowing in LocalStore+SpaceURLRule.swift (R-exec-2).
    /// After success, reread in place for the per-page refresh required by R-M3-4a-62. If rereading throws,
    /// propagate it, but the batch is already committed. Callers must treat this as successful persistence
    /// with a stale snapshot, matching AccountPhiBookmarkAccess.apply.
    @discardableResult
    func apply(_ batch: URLRuleApplyBatch) async throws -> URLRuleBatchOutcome {
        let outcome = try await store.applyURLRuleSyncBatchThrowing(batch.ops,
                                                                    mergeTail: batch.mergeTail)
        try rebuildCache()
        return outcome
    }

    /// urlRulesPublisher alone is insufficient: removeDuplicates in LocalStore+SpaceURLRule.swift compares the
    /// same SwiftData instances refreshed in place and suppresses host-only changes. The engine calls this
    /// once per page, only after apply succeeds.
    func refreshRoutingTableAfterLanding() {
        SpaceManager.shared.reloadURLRulesFromStore()
    }

    // MARK: - §5.7 Two exits for soft-deleted rows

    /// Delegate to Task 5's hardDeleteURLRuleThrowing(syncId:); an absent row is a no-op. Leave the page cache
    /// intact: exit 1 runs at the end of publishing, after landing. The next page or round rebuilds it through
    /// allURLRules().
    func hardDeleteURLRule(syncId: String) async throws {
        try await store.hardDeleteURLRuleThrowing(syncId: syncId)
    }

    /// Read allURLRulesIncludingDeleted() once, select identified soft-deleted rows with deletedDate < cutoff,
    /// and hard-delete each. Separate transactions deliberately allow the next cleanup round to retry
    /// remaining rows after a crash; no one-shot state is used. A soft-deleted row with nil syncId is
    /// unreachable because insertion mints it (R-M3-4a-23). Use the row's deletedDate, independent of cursors.
    /// Continue after individual failures and count successful deletes. Log one R12 summary with kind and
    /// failure count at the end; failed rows are reconsidered next cleanup round. Only the initial read
    /// throws.
    func purgeSoftDeletedURLRules(olderThan cutoff: Date) async throws -> Int {
        let expired = try allURLRulesIncludingDeleted().compactMap { row -> String? in
            guard let deletedDate = row.deletedDate, deletedDate < cutoff else { return nil }
            return row.syncId
        }
        var purged = 0
        var failed = 0
        for syncId in expired {
            do {
                try await store.hardDeleteURLRuleThrowing(syncId: syncId)
                purged += 1
            } catch {
                failed += 1
            }
        }
        if failed > 0 {
            AppLogWarn("[phi-sync] soft-deleted rule sweep: some rows could not be hard-deleted "
                       + "kind=urlrules failed=\(failed)")
        }
        return purged
    }

    // MARK: - D30 (8b-1): Four read-only queries and two in-place updates

    /// All queries use this page's cachedRows / cachedLive from Task 8, with no extra fetch. A missing
    /// snapshot returns an empty value and asserts in DEBUG via requireLoadedSnapshot().
    func signatureIndex(resolve: OwnerResolver) -> [RuleSignature: [PhiLocalURLRule]] {
        guard requireLoadedSnapshot() else { return [:] }
        return URLRuleSignatureQueries.signatureIndex(rows: cachedLive, resolve: resolve)
    }

    func pendingLocalEditIdentities(resolve: OwnerResolver) -> Set<String> {
        guard requireLoadedSnapshot() else { return [] }
        return URLRuleSignatureQueries.pendingLocalEditIdentities(rows: cachedLive, resolve: resolve)
    }

    func unpublishedIdentities(table: PhiOwnedItemTable, resolve: OwnerResolver) -> Set<String> {
        guard requireLoadedSnapshot() else { return [] }
        return URLRuleSignatureQueries.unpublishedIdentities(rows: cachedLive, table: table,
                                                             resolve: resolve)
    }

    func mergePartners(table: PhiOwnedItemTable, resolve: OwnerResolver,
                       tombstonesThisPage: Set<String>) -> [String: String] {
        guard requireLoadedSnapshot() else { return [:] }
        return URLRuleSignatureQueries.mergePartners(rows: cachedRows, table: table, resolve: resolve,
                                                     tombstonesThisPage: tombstonesThisPage)
    }

    /// Locate the row by local id and update its syncId in both caches (local row id -> new syncId). apply(_:)
    /// has already rebuilt the cache on success, so this is normally idempotent. It makes R-M3-4a-62's
    /// contract explicit instead of relying on apply's incidental reread.
    func notePersistedClaims(_ claimed: [String: String]) {
        guard requireLoadedSnapshot(), !claimed.isEmpty else { return }
        for index in cachedRows.indices {
            guard let syncId = claimed[cachedRows[index].id] else { continue }
            cachedRows[index].syncId = syncId
        }
        reindexLive()
    }

    /// Remove rows actually deleted this page from both caches by syncId. Relinquished identities must never
    /// enter this set (R-M3-4a-61).
    func noteDeletedRows(_ syncIds: Set<String>) {
        guard requireLoadedSnapshot(), !syncIds.isEmpty else { return }
        cachedRows.removeAll { row in
            guard let syncId = row.syncId else { return false }
            return syncIds.contains(syncId)
        }
        reindexLive()
    }

    // MARK: - D30 (8b-4): Two flag-clearing points in §8.4.5

    /// Delegate without changing the page cache. Both flag-clearing paths run during publishing, outside the
    /// page loop and after landing. The next page or round rebuilds it via allURLRules(), matching
    /// hardDeleteURLRule(syncId:).
    @discardableResult
    func clearPendingLocalEdit(syncId: String,
                               ifProjectionEquals confirmed: RuleProjection) async throws -> Bool {
        try await store.clearPendingLocalEditThrowing(syncId: syncId, ifProjectionEquals: confirmed)
    }

    func clearPendingLocalEditIfUnchanged(entries: [String: RuleProjection]) async throws {
        try await store.clearPendingLocalEditIfUnchangedThrowing(entries: entries)
    }

    // MARK: - Private

    /// Rebuild the other three derived caches from cachedRows after either in-place update.
    private func reindexLive() {
        let live = cachedRows.filter { $0.deletedDate == nil }
        var siblings: [String: [PhiLocalURLRule]] = [:]
        var liveSyncIds: Set<String> = []
        for row in live {
            siblings[row.spaceId, default: []].append(row)
            if let syncId = row.syncId {
                liveSyncIds.insert(syncId)
            }
        }
        cachedLive = live
        cachedSiblings = siblings
        cachedLiveSyncIds = liveSyncIds
    }

    private func invalidateCache() {
        cachedRows = []
        cachedLive = []
        cachedSiblings = [:]
        cachedLiveSyncIds = []
        snapshotIsLoaded = false
    }

    /// Shared precondition for the two nonthrowing readers. On false, callers can only return an incorrect
    /// absence value, so assert in DEBUG to expose misuse immediately in engine tests.
    private func requireLoadedSnapshot() -> Bool {
        if !snapshotIsLoaded {
            assertionFailure("read the url rule snapshot before a successful allURLRules()/apply()")
        }
        return snapshotIsLoaded
    }

    /// Clear the cache first and throw every failure (R-exec-3), matching
    /// AccountPhiBookmarkAccess.rebuildCache(). One FetchDescriptor<SpaceURLRule>() includes soft-deleted rows
    /// and replaces both row sets and both indexes together.
    private func rebuildCache() throws {
        invalidateCache()
        guard let context = store.getMainContext() else {
            AppLogError("[phi-sync] url rule snapshot failed: no main context")
            throw LocalStoreWriteError.storeUnavailable
        }
        let models: [SpaceURLRule]
        do {
            models = try store.allURLRuleModelsIncludingDeleted(in: context)
        } catch {
            AppLogError("[phi-sync] url rule snapshot fetch failed: \(PhiSyncLog.describe(error))")
            throw error
        }
        // The (spaceId, sortOrder, id) order is contractual: diff emits commits in this order and index
        // projections use it.
        let rows = models.map(Self.project).sorted {
            ($0.spaceId, $0.sortOrder, $0.id) < ($1.spaceId, $1.sortOrder, $1.id)
        }
        let live = rows.filter { $0.deletedDate == nil }
        var siblings: [String: [PhiLocalURLRule]] = [:]
        var liveSyncIds: Set<String> = []
        for row in live {
            siblings[row.spaceId, default: []].append(row)
            if let syncId = row.syncId {
                liveSyncIds.insert(syncId)
            }
        }
        cachedRows = rows
        cachedLive = live
        cachedSiblings = siblings
        cachedLiveSyncIds = liveSyncIds
        snapshotIsLoaded = true
    }

    /// Copy values, never model objects; see PhiLocalURLRule.
    private static func project(_ model: SpaceURLRule) -> PhiLocalURLRule {
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
}

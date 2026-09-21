// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

/// Sync-visible value snapshot of a local bookmark/folder, like PhiLocalSpace (PhiSpaceLocalAccess.swift:13).
/// Lives in Sync/Phi without LocalStorage dependencies so tests can construct the sync layer without
/// SwiftData. Adds contentUpdatedDate to §4.8's 13 fields for §6.2's contentUpdatedDate ?? createdDate
/// comparison.
struct PhiLocalBookmark: Equatable, Sendable {
    /// Lowercase account UUID, minted on first publication and persisted to TabDataModel.syncId. Nil means
    /// unpublished. Never a local GUID, which is uppercase, device-scoped and reminted on cloning.
    var syncId: String?
    /// Physical local row ID used by every landing operation.
    var guid: String
    var spaceId: String
    var profileId: String
    /// nil means attached directly to the Space's canonical root.
    var parentGuid: String?
    var index: Int
    var isFolder: Bool
    var title: String
    /// Folders carry placeholder URL https://bookmark.phi/folder.
    var url: URL
    var secondaryUrl: URL?
    var secondaryTitle: String?
    /// TabSource raw value: 0 phi, 1 chromium, 2 safari, 3 arc.
    var source: Int
    var createdDate: Date
    /// nil means content was never edited; use createdDate for comparison (§6.2).
    var contentUpdatedDate: Date?
    /// Last local user move of the §4.3 location merge unit (parent and Space share one stamp). nil means no
    /// recorded move — a create, a pre-V13 row, or a row whose location only ever arrived from a peer — and
    /// `BookmarkKind.stamp` then falls back to the round clock as it did before V13.
    var locationUpdatedDate: Date?
}

/// Fields and values for one update. Nested optionals: outer selects whether to change, inner selects the
/// value, with nil clearing it. All four default to nil, supporting title-only patches.
struct BookmarkFieldPatch: Equatable {
    var title: String?? = nil
    var url: URL?? = nil
    var secondaryUrl: URL?? = nil
    var secondaryTitle: String?? = nil
}

/// One local write required to land a remote bookmark.
enum BookmarkApplyOp: Equatable {
    /// Claim an account UUID on an existing local row by writing syncId only, without content edits.
    case claim(guid: String, syncId: String)
    case create(PhiLocalBookmark)
    /// Location change writes parent, Space and sibling position together (§4.3).
    case move(guid: String, toParentGuid: String?, inSpaceId: String, index: Int)
    case update(guid: String, fields: BookmarkFieldPatch)
    case delete(guid: String)
}

/// All bookmark operations for one remote landing round, ordered by §4.4. A list is required: a single enum
/// operation cannot express §4.5's multi-row transaction per round.
struct BookmarkApplyBatch {
    private(set) var ops: [BookmarkApplyOp]

    /// §4.4 phase order: claim/create/move parent-first; update; delete child-first. parentOf describes the
    /// round's resulting child→parent relationships and is used only for depth, not operation inference.
    /// Missing GUIDs have depth 0 because they are roots or have untouched parents. Stable sorting preserves
    /// input order at equal phase/depth.
    init(unordered: [BookmarkApplyOp], parentOf: [String: String] = [:]) {
        let depths = Self.depths(of: unordered.map(Self.targetGuid), parentOf: parentOf)
        let ordered = unordered.enumerated().sorted { lhs, rhs in
            let lhsPhase = Self.phase(lhs.element)
            let rhsPhase = Self.phase(rhs.element)
            if lhsPhase != rhsPhase { return lhsPhase < rhsPhase }
            let lhsDepth = depths[Self.targetGuid(lhs.element)] ?? 0
            let rhsDepth = depths[Self.targetGuid(rhs.element)] ?? 0
            if lhsDepth != rhsDepth {
                // Delete children before parents; other phases are parent-first.
                return lhsPhase == 3 ? lhsDepth > rhsDepth : lhsDepth < rhsDepth
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
        self.ops = ordered
        assert(Self.noDeleteBeforeItsDescendants(ordered, parentOf: parentOf),
               "a delete must never precede an operation targeting one of its descendants")
    }

    /// ① claim / create / move ② update ③ delete。
    private static func phase(_ op: BookmarkApplyOp) -> Int {
        switch op {
        case .claim, .create, .move: return 1
        case .update: return 2
        case .delete: return 3
        }
    }

    /// Physical local row targeted by each operation.
    private static func targetGuid(_ op: BookmarkApplyOp) -> String {
        switch op {
        case .claim(let guid, _): return guid
        case .create(let row): return row.guid
        case .move(let guid, _, _, _): return guid
        case .update(let guid, _): return guid
        case .delete(let guid): return guid
        }
    }

    /// Follow parentOf upward, bounded by parentOf.count. Corrupt local cycles become finite depths instead of
    /// hanging landing.
    private static func depths(of guids: [String],
                               parentOf: [String: String]) -> [String: Int] {
        var out: [String: Int] = [:]
        let limit = parentOf.count
        for guid in guids where out[guid] == nil {
            var depth = 0
            var cursor = parentOf[guid]
            while let parent = cursor, depth < limit {
                depth += 1
                cursor = parentOf[parent]
            }
            out[guid] = depth
        }
        return out
    }

    /// Invariant: no delete precedes an operation targeting its descendants.
    private static func noDeleteBeforeItsDescendants(_ ops: [BookmarkApplyOp],
                                                     parentOf: [String: String]) -> Bool {
        var deletedAt: [String: Int] = [:]
        for (index, op) in ops.enumerated() {
            if case .delete(let guid) = op { deletedAt[guid] = index }
        }
        guard !deletedAt.isEmpty else { return true }
        let limit = parentOf.count
        for (index, op) in ops.enumerated() {
            var hops = 0
            var cursor = parentOf[targetGuid(op)]
            while let ancestor = cursor, hops < limit {
                if let deleteIndex = deletedAt[ancestor], deleteIndex < index { return false }
                cursor = parentOf[ancestor]
                hops += 1
            }
        }
        return true
    }
}

/// Sole engine/local-bookmark boundary. The engine actor hops to the main actor as for PhiSpaceLocalAccess
/// (PhiSpaceLocalAccess.swift:47). All writes are async throws so baselines advance only after real landing
/// (§5.6).
///
/// Refines PhiFaviconWriting (§8.2 / Task 10), exposing only favicon writes to the backfill queue, never
/// snapshots/diff/apply. Favicon is deliberately not a BookmarkApplyOp: it is absent from snapshots and should
/// not join phase sorting, landing transactions or §5.7 deduplication fields. AccountPhiBookmarkAccess below
/// is the production implementation.
@MainActor
protocol PhiBookmarkLocalAccess: PhiFaviconWriting {
    /// One relationship-prefetched fetch per round, reused for snapshot, diff and index projection. Order by
    /// (spaceId, parentGuid, index, guid), with parentless rows first per Space (§4.8); all consumers depend
    /// on this order. Exclude root rows and expose canonical-root children with nil parentGuid. Exclude entire
    /// orphan-root subtrees outside the canonical set.
    ///
    /// Throw on every read failure (R-exec-3), never return [] or a stale snapshot: §4.7 interprets empty as
    /// deleting every mapped row and emits tombstones across the account.
    func allBookmarks() throws -> [PhiLocalBookmark]

    /// All local syncIds without root filtering (R-exec-4), used for §4.7 diff instead of allBookmarks.
    /// Orphan-root descendants remain unpublished but are never treated as deleted: unclaimed by sync is not
    /// absent locally. Reuse the same pre-filter fetch as the snapshot (L9), avoiding an actor-hop race that
    /// could publish and tombstone a user-deleted row in one round. Throw if this round has no successful
    /// fetch; never perform a replacement query.
    func allSyncIds() throws -> Set<String>

    /// Latest successful allBookmarks/apply value snapshot from this round, in the same order, without
    /// fetching again (§5.7 item 2). Same-round outbound projection must see landed fields (§4.2 / §4.5);
    /// stale pre-landing values would look like fresh local edits, receive now, and overwrite the remote
    /// winner.
    ///
    /// Nil means no usable snapshot: unread, failed read, or committed apply whose final reread failed. The
    /// caller preserves its existing round projection rather than replacing it with an empty array.
    func cachedBookmarks() -> [PhiLocalBookmark]?

    /// In-memory grouping of the allBookmarks fetch by (spaceId, parentGuid), not a second fetch. Do not
    /// filter siblings: §4.10 normalization must account for excluded rows' stale indices.
    ///
    /// This and isKnownLocalBookmark/localIsFolder share the latest successful allBookmarks/apply cache. Apply
    /// rereads after commit, supporting §4.5 validation before baselines without another explicit fetch. If
    /// unread or either read failed, return empty/false/nil with DEBUG assertionFailure, never silently
    /// refetch through nonthrowing APIs. Apply may already have committed despite a failed reread; unknown
    /// must not silently make the engine recreate the tree.
    func siblings(ofParent parentGuid: String?, inSpaceId spaceId: String) -> [PhiLocalBookmark]

    /// Whether the physical local row exists, as with isKnownLocalSpace. Reverse syncId lookup merely rereads
    /// the mapping that supplied the ID and would always answer yes.
    func isKnownLocalBookmark(_ guid: String) -> Bool

    /// Physical local row type, or nil if absent. Used by §4.6 is_folder checks: refuses against cursor
    /// baselines cannot detect a resolved row whose dataType disagrees with the payload.
    func localIsFolder(guid: String) -> Bool?

    /// Whether this Space is importing; do not publish its rows while ImportTargetLock is held.
    func isImporting(intoSpaceId spaceId: String) -> Bool

    /// One remote landing round in one transaction (§4.5). Throw means no rows landed and forbids baseline
    /// writes.
    func apply(_ batch: BookmarkApplyBatch) async throws

    /// Clear all syncIds on account exit or sync reset (§9.2).
    func clearAllSyncIds() async throws
}

/// Production counterpart of AccountPhiSpaceAccess (PhiSpaceLocalAccess.swift:142), retaining
/// Account.localStorage on the main actor with pure reads and throwing async writes.
///
/// One fetch per round (§4.8 / §5.7): allBookmarks builds value snapshots, sibling groups and GUID→folder-type
/// index. Other readers reuse these caches without fetching.
@MainActor
final class AccountPhiBookmarkAccess: PhiBookmarkLocalAccess {
    private let account: Account

    /// Sibling-group key; nil parentGuid means directly under the Space's canonical root.
    private struct SiblingKey: Hashable {
        var spaceId: String
        var parentGuid: String?
    }

    /// This round's fetch projection, rebuilt by allBookmarks and reused by the three other readers.
    private var cachedRows: [PhiLocalBookmark] = []
    private var cachedSiblings: [SiblingKey: [PhiLocalBookmark]] = [:]
    private var cachedIsFolder: [String: Bool] = [:]
    /// Diff domain: all fetched identities captured before root filtering (L9 / R-exec-4).
    private var cachedSyncIds: Set<String> = []
    /// Distinguish a valid empty snapshot from unreadable state. Otherwise nonthrowing readers could silently
    /// report every row missing and make the engine recreate the tree.
    private var snapshotIsLoaded = false

    init(account: Account) {
        self.account = account
    }

    // MARK: - Reads

    /// One fetch with parent/profile prefetched plus canonical-root resolution; all remaining work is in
    /// memory. Traverse downward from canonical roots rather than subtracting root rows from all rows:
    /// read-only existingBookmarkRoot does not heal orphan roots (LocalStore+Bookmark.swift:1389), so
    /// subtraction would publish invisible subtrees that UI healing can later merge/delete (§4.8 / R-M3-3-19).
    /// Throw on failure (R-exec-3); clear caches first so failed reads expose no stale values.
    func allBookmarks() throws -> [PhiLocalBookmark] {
        try rebuildCache()
        return cachedRows
    }

    /// Capture identities from the same fetch before root traversal (R-exec-4 / L9), including orphan-root
    /// descendants. Throw without a successful round snapshot; an empty set means all identities disappeared
    /// and would tombstone every cursor (§4.7).
    func allSyncIds() throws -> Set<String> {
        guard snapshotIsLoaded else {
            AppLogError("[phi-sync] bookmark identities read before a successful snapshot")
            throw LocalStoreWriteError.storeUnavailable
        }
        return cachedSyncIds
    }

    /// Return the fetch snapshot without refetching. Apply rebuilds it after commit so this round's outbound
    /// projection sees landed state. Return nil when unavailable, never [] that would empty the outbound
    /// snapshot; see protocol contract.
    func cachedBookmarks() -> [PhiLocalBookmark]? {
        guard snapshotIsLoaded else { return nil }
        return cachedRows
    }

    /// Read the group cache without fetching or filtering; §4.10 needs all siblings.
    func siblings(ofParent parentGuid: String?, inSpaceId spaceId: String) -> [PhiLocalBookmark] {
        guard requireLoadedSnapshot() else { return [] }
        return cachedSiblings[SiblingKey(spaceId: spaceId, parentGuid: parentGuid)] ?? []
    }

    /// Test membership in this round's snapshot rather than arbitrary database GUID existence. Excluded
    /// orphan-root subtrees are outside sync's snapshot domain; keep this predicate consistent with cached
    /// projections and sibling indexing.
    func isKnownLocalBookmark(_ guid: String) -> Bool {
        guard requireLoadedSnapshot() else { return false }
        return cachedIsFolder[guid] != nil
    }

    /// Read physical type from the fetch cache without another query; absent means nil.
    func localIsFolder(guid: String) -> Bool? {
        guard requireLoadedSnapshot() else { return nil }
        return cachedIsFolder[guid]
    }

    func isImporting(intoSpaceId spaceId: String) -> Bool {
        ImportTargetLock.shared.isImporting(into: spaceId)
    }

    // MARK: - Writes

    /// Apply one remote round in one transaction (§4.5); failure forbids baseline writes. Thin forwarding to
    /// LocalStore.applyBookmarkSyncBatchThrowing owns transaction, phase execution, in-write import recheck
    /// and final per-parent normalization. Its private helpers are inaccessible here, and composing individual
    /// throwing calls would create N transactions and partial success (R-exec-2).
    func apply(_ batch: BookmarkApplyBatch) async throws {
        try await account.localStorage.applyBookmarkSyncBatchThrowing(batch.ops)
        // Rebuild the stale cache after landing rather than merely clearing it. §4.5 validates the plan before
        // saving baselines through cached readers; an empty cache would fail every validation, endlessly
        // replay the batch, or make all identities look dead and recreate the tree.
        //
        // Reread failure propagates after the batch has already committed: callers must treat it as landed
        // with an unavailable snapshot, not an unapplied batch. Readers remain invalid until the next
        // successful allBookmarks.
        try rebuildCache()
    }

    /// Narrow backfill-only write (§8.2 / Task 10), combining the round into one background transaction. Leave
    /// caches untouched: favicon is absent from PhiLocalBookmark and cannot change snapshot values, diff, §5.7
    /// deduplication or cursors. This prevents backfill-triggered pushes.
    func setFavicon(_ writes: [(guid: String, data: Data)]) async throws {
        try await account.localStorage.updateTabFaviconsThrowing(
            writes.map { (guid: $0.guid, favicon: $0.data) })
    }

    /// One bulk write (§9.2), avoiding thousands of transactions for a large tree.
    func clearAllSyncIds() async throws {
        try await account.localStorage.clearAllBookmarkSyncIdsThrowing()
        // Self-revocation/account reset has no later readers this round; invalidate without rereading.
        invalidateCache()
    }

    // MARK: - Private helpers

    /// Clear rather than retain: siblings/localIsFolder must not silently serve stale shapes.
    private func invalidateCache() {
        cachedRows = []
        cachedSiblings = [:]
        cachedIsFolder = [:]
        cachedSyncIds = []
        snapshotIsLoaded = false
    }

    /// Shared precondition for nonthrowing readers. On failure their signatures can only return absent
    /// defaults, which are not valid knowledge. Assert in DEBUG so misuse is caught by Task 6 tests instead of
    /// silently recreating a duplicate tree.
    private func requireLoadedSnapshot() -> Bool {
        if !snapshotIsLoaded {
            assertionFailure("read the bookmark snapshot before a successful allBookmarks()/apply()")
        }
        return snapshotIsLoaded
    }

    /// Always clear caches first and throw on failure (R-exec-3). Neither fake-empty nor stale snapshots are
    /// safe: [] causes §4.7 tombstones for the whole tree, while stale values after committed apply
    /// misrepresent pre-landing data as fresh. Task 6's engine handling skips this kind's
    /// snapshot/diff/publication and counts local_read_failed.
    private func rebuildCache() throws {
        invalidateCache()
        let store = account.localStorage
        guard let context = store.getMainContext() else {
            AppLogError("[phi-sync] bookmark snapshot failed: no main context")
            throw LocalStoreWriteError.storeUnavailable
        }
        let models: [TabDataModel]
        let roots: Set<String>
        do {
            models = try store.allBookmarkModels(in: context)
            roots = try store.canonicalRootGuids(in: context)
        } catch {
            // R12: log only type and domain/code, never row content.
            AppLogError("[phi-sync] bookmark snapshot fetch failed: \(PhiSyncLog.describe(error))")
            throw error
        }

        // Capture diff identities before root traversal, including orphan-root descendants (R-exec-4). Reuse
        // the snapshot fetch so there is no intervening moment/race (L9).
        let syncIds = Set(models.compactMap(\.syncId))

        // Build parent-child links in memory from one fetch. Prefetched parent relationships avoid further
        // faults or queries during canonical-root traversal.
        var childrenByParent: [String: [TabDataModel]] = [:]
        for model in models {
            guard let parentGuid = model.parent?.guid else { continue }
            childrenByParent[parentGuid, default: []].append(model)
        }

        var rows: [PhiLocalBookmark] = []
        // Roots are never snapshot rows (§3.4 rule 1); their direct children carry projected nil parentGuid in
        // the queue.
        var queue: [(model: TabDataModel, parentGuid: String?)] = []
        for rootGuid in roots {
            for child in childrenByParent[rootGuid] ?? [] {
                queue.append((child, nil))
            }
        }
        var cursor = 0
        while cursor < queue.count {
            let (model, parentGuid) = queue[cursor]
            cursor += 1
            let row = Self.project(model, parentGuid: parentGuid)
            rows.append(row)
            if row.isFolder {
                for child in childrenByParent[model.guid] ?? [] {
                    queue.append((child, model.guid))
                }
            }
        }

        // §4.8 ordering is contractual: spaceId, parentGuid, index, guid, with nil parent represented as empty
        // and sorting before real GUIDs. Diff commit order and index projection both rely on it.
        rows.sort {
            ($0.spaceId, $0.parentGuid ?? "", $0.index, $0.guid)
                < ($1.spaceId, $1.parentGuid ?? "", $1.index, $1.guid)
        }
        // Replace snapshot and all three indices together, with no intermediate row/index mismatch.
        var siblings: [SiblingKey: [PhiLocalBookmark]] = [:]
        var isFolder: [String: Bool] = [:]
        for row in rows {
            siblings[SiblingKey(spaceId: row.spaceId, parentGuid: row.parentGuid),
                     default: []].append(row)
            isFolder[row.guid] = row.isFolder
        }
        cachedRows = rows
        cachedSiblings = siblings
        cachedIsFolder = isFolder
        cachedSyncIds = syncIds
        snapshotIsLoaded = true
    }

    /// Use value snapshots, not models: SwiftData mutates the same instances and object-based deduplication
    /// would swallow actual edits (§4.8).
    private static func project(_ model: TabDataModel, parentGuid: String?) -> PhiLocalBookmark {
        PhiLocalBookmark(syncId: model.syncId,
                         guid: model.guid,
                         spaceId: model.spaceId ?? LocalStore.defaultSpaceId,
                         profileId: model.profileId ?? LocalStore.defaultProfileId,
                         parentGuid: parentGuid,
                         index: model.index,
                         isFolder: model.dataType == .bookmarkFolder,
                         title: model.title,
                         url: model.url,
                         secondaryUrl: model.secondaryUrl,
                         secondaryTitle: model.secondaryTitle,
                         source: model.source,
                         createdDate: model.createdDate,
                         contentUpdatedDate: model.contentUpdatedDate,
                         locationUpdatedDate: model.locationUpdatedDate)
    }
}

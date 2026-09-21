// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

/// Sync-visible value snapshot of a local pin, independent of LocalStorage like PhiLocalBookmark.
struct PhiLocalPin: Equatable, Sendable {
    /// Raw local pinLineageId bytes, only half the identity: (lineageId, owner) identifies a pin (R-M3-3-15),
    /// so one lineage in N Spaces is N entities.
    ///
    /// P11: not necessarily lowercase; normalize every comparison with PinKind.lineageKey. normalizeVariants
    /// mints uppercase UUIDs, legacy rows fall back to uppercase GUIDs, and only wire input is already
    /// lowercase. Preserve stored bytes during projection to avoid false read-time changes; normalize at
    /// comparison boundaries.
    var lineageId: String
    /// Physical local row ID used by every landing operation.
    var guid: String
    /// §7.2 scope shape: Space has both spaceId and profileId; Profile has only profileId; App has neither.
    /// Resolve owner by checking spaceId before profileId, not arbitrarily choosing a nonnil value.
    var spaceId: String?
    /// Present for Space and Profile scopes, absent only for App; see spaceId.
    var profileId: String?
    var index: Int
    var title: String
    var url: URL
    /// Partner lineage, nil when not split. Never the device/copy-specific physical splitPartnerGuid.
    var splitPartnerLineageId: String?
    /// TabSource raw value.
    var source: Int
    var createdDate: Date
    /// nil means never content-edited; fall back to createdDate for comparison (§6.2).
    var contentUpdatedDate: Date?
    /// Dormant rows participate in neither snapshots nor diff.
    var isDormant: Bool
}

/// Pin field patch, using BookmarkFieldPatch's nested-optionals contract: outer selects whether to change;
/// inner selects the value, with nil clearing it.
struct PinFieldPatch: Equatable {
    var title: String?? = nil
    var url: URL?? = nil
    var splitPartnerLineageId: String?? = nil
}

/// One local write for landing a remote pin.
enum PinApplyOp: Equatable {
    case create(PhiLocalPin)
    /// Assign a different lineage to an existing row. This is not owner change: changing owner always
    /// tombstones the old tag and creates a new tag, never updates fields (§7.2).
    case relineage(guid: String, newLineageId: String)
    case move(guid: String, index: Int)
    case update(guid: String, fields: PinFieldPatch)
    case delete(guid: String)
}

/// All ordered pin operations for one remote round in one transaction, as with BookmarkApplyBatch.
struct PinApplyBatch {
    private(set) var ops: [PinApplyOp]

    /// Stable three-phase order, like bookmarks without parent depth: create/relineage/move → update → delete.
    init(unordered: [PinApplyOp]) {
        self.ops = unordered.enumerated().sorted { lhs, rhs in
            let lhsPhase = Self.phase(lhs.element)
            let rhsPhase = Self.phase(rhs.element)
            if lhsPhase != rhsPhase { return lhsPhase < rhsPhase }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    private static func phase(_ op: PinApplyOp) -> Int {
        switch op {
        case .create, .relineage, .move: return 1
        case .update: return 2
        case .delete: return 3
        }
    }
}

/// Sole engine/local-pin boundary, with PhiBookmarkLocalAccess's isolation and throwing guarantees. Refine
/// PhiFaviconWriting for narrow backfill access (§8.2 / Task 10), never a PinApplyOp.
/// AccountPhiPinnedTabAccess below is production.
@MainActor
protocol PhiPinnedTabLocalAccess: PhiFaviconWriting {
    /// Scope stored in the local SwiftData singleton row.
    func currentScope() -> PinnedTabScope

    /// Account scope from Task 8's mirror preference, nil before an account value lands. §7.3 compares these
    /// two APIs; the engine never accesses LocalStore/UserDefaults directly.
    func accountScope() -> PinnedTabScope?

    /// All non-dormant rows in current scope, ordered by ownerKey/index/GUID. Never choose just one
    /// representative per lineage: other unpublished variants would silently escape both snapshot and diff.
    /// Throw on read failure (R-exec-3), never return [] or stale data: §4.7 interprets empty as tombstones
    /// for every cursor and deletes all account pins.
    func allPins() throws -> [PhiLocalPin]

    /// Diff and §9.3 cascade domain: every non-dormant local pin row without scope filtering (R-exec-4).
    /// Unlike allPins' claimed rows, this answers whether an identity still has a local row (§4.7). Keep
    /// out-of-scope migration backups protected, but exclude dormant rows per contract.
    ///
    /// Return rows, not bare lineages (R-exec-11). Callers own OwnerResolver and derive the full (lineage,
    /// owner) identity with the same PinKind.identity helper as outbound snapshots. Each row protects only its
    /// own owner-specific identity; a Profile backup must not protect a missing Space pin, as happened on Mac
    /// B on 2026-09-14.
    ///
    /// Reuse the snapshot's pre-scope-filter fetch (L9). If no successful read exists this round, throw; never
    /// refetch or return an empty domain.
    func allPinRows() throws -> [PhiLocalPin]

    /// Latest successful allPins/apply snapshot this round, with identical scope/dormancy filtering and order,
    /// without fetching (§5.7 item 2). Outbound projection must see landed values; stale values with a fresh
    /// now stamp would undo remote edits, as for cachedBookmarks. Nil means unavailable; preserve the caller's
    /// existing projection rather than emptying it.
    func cachedPins() -> [PhiLocalPin]?

    /// Whether this full (lineage, owner) identity has a local row (R-M3-3-15), never lineage alone. Otherwise
    /// a row in Space Y could falsely validate a missing Space X landing or indefinitely park its deletion.
    ///
    /// ownerKey uses local IDs via PinKind.localOwnerKey (Space, then Profile, then app), not account UUIDs.
    /// Callers reverse-resolve first; nil means no corresponding local owner and therefore absent. Exclude
    /// out-of-scope backups, matching allPins: this validates claimed rows, while allPinRows protects the
    /// broader diff domain.
    ///
    /// Normalize local lineage through lineageKey before comparing wire lowercase input (P11), avoiding false
    /// absence for uppercase UUIDs. Read only this round's latest successful allPins/apply cache. If unread,
    /// failed or unavailable after committed apply's reread failure, return false and assert in DEBUG;
    /// nonthrowing absence defaults must not silently trigger mass tombstones.
    func isKnownLocalPin(_ lineageId: String, ownerKey: String?) -> Bool

    /// One remote landing round in one transaction. Throw means none landed.
    func apply(_ batch: PinApplyBatch) async throws

    /// Scope migration takes both preferred arguments by plan ruling, extending spec §4.8's signature. §7.1
    /// requires matching UI arguments (SpacesSettingsView.swift:501-512): sourceCollections sorts preferred
    /// first and mergeCandidates takes that source. Omitting them could yield different pins/order for local
    /// versus remote changes.
    func changeScope(to scope: PinnedTabScope,
                     preferredProfileId: String?,
                     preferredSpaceId: String?) async throws
}

/// Main-actor production counterpart of AccountPhiBookmarkAccess, with pure reads and async throwing writes.
/// Inject LocalStore directly rather than Account: its lazy localStorage opens real user data, preventing
/// production-access tests on the bookmark side. The coordinator already has the store, so behavior is
/// unchanged; bookmark injection remains follow-up.
///
/// One fetch per round (§4.8 / §5.7): allPins builds value snapshots and both derived caches;
/// allPinRows/isKnownLocalPin reuse them.
@MainActor
final class AccountPhiPinnedTabAccess: PhiPinnedTabLocalAccess {
    private let store: LocalStore
    private let defaults: UserDefaults

    /// Read-only Task 8 scope mirror: missing/unrecognized values return nil, meaning no published account
    /// scope and no mismatch. PinnedTabScopeMirror owns writes and the shared key constant. Duplicating its
    /// literal could silently disable §7.3 mismatch checks without unhealthy counters.
    private static var accountScopeKey: String { PinnedTabScopeMirror.key }

    /// This round's fetch projection, rebuilt by allPins and reused by other readers.
    private var cachedRows: [PhiLocalPin] = []
    /// Full normalized-lineage:local-owner identities for isKnownLocalPin. Derived from scope-filtered active
    /// rows and includes owner: both are intentional, answering whether this round's claimed domain contains
    /// the identity.
    private var cachedIdentityPairs: Set<String> = []
    /// Non-dormant rows before scope filtering from the same fetch, for diff/cascade (L9 / R-exec-4 /
    /// R-exec-11). Active snapshot rows are a subset.
    private var cachedFullStoreRows: [PhiLocalPin] = []
    /// Distinguish a valid empty snapshot from unreadability; silent false isKnownLocalPin defaults could
    /// trigger tombstones for the whole batch.
    private var snapshotIsLoaded = false

    init(store: LocalStore, defaults: UserDefaults = .standard) {
        self.store = store
        self.defaults = defaults
    }

    // MARK: - Reads

    func currentScope() -> PinnedTabScope {
        store.pinnedTabScope()
    }

    /// Missing/invalid scope key returns nil, never profile. A fallback would fabricate an account value and
    /// make a Space-scoped device stop all pin sync for a false §7.3 mismatch.
    func accountScope() -> PinnedTabScope? {
        guard let raw = defaults.string(forKey: Self.accountScopeKey) else { return nil }
        return PinnedTabScope(rawValue: raw)
    }

    /// One profile-prefetched fetch plus one scope read; remaining work is in memory. Throw on failure after
    /// clearing caches, never expose stale values (R-exec-3).
    func allPins() throws -> [PhiLocalPin] {
        try rebuildCache()
        return cachedRows
    }

    /// Same snapshot fetch before scope filtering (R-exec-4 / L9). Throw without a successful round read: []
    /// means no local pins and triggers §4.7 tombstones for every cursor.
    func allPinRows() throws -> [PhiLocalPin] {
        guard snapshotIsLoaded else {
            AppLogError("[phi-sync] pin identities read before a successful snapshot")
            throw LocalStoreWriteError.storeUnavailable
        }
        return cachedFullStoreRows
    }

    /// Return the fetch snapshot without refetching. Apply rebuilds it so same-round outbound projection sees
    /// landed values. Unavailable returns nil, never [] that would empty outbound state.
    func cachedPins() -> [PhiLocalPin]? {
        guard snapshotIsLoaded else { return nil }
        return cachedRows
    }

    /// Normalize both sides with lineageKey (P11): local UUID/GUID fallbacks may be uppercase, unlike wire
    /// input. Nil owner means reverse resolution found no possible local owner, hence absent. Check snapshot
    /// validity first so this legitimate absence cannot hide misuse in DEBUG.
    func isKnownLocalPin(_ lineageId: String, ownerKey: String?) -> Bool {
        guard requireLoadedSnapshot() else { return false }
        guard let ownerKey else { return false }
        return cachedIdentityPairs.contains(PinKind.lineageKey(lineageId) + ":" + ownerKey)
    }

    // MARK: - Writes

    /// One remote round in one transaction (§4.5), with failure forbidding baselines. Thin forwarding to
    /// LocalStore.applyPinSyncBatchThrowing owns phase execution, in-write import recheck and per-owner
    /// normalization. Private storage helpers are inaccessible here; separate throwing calls would create
    /// partial success across N transactions (R-exec-2).
    func apply(_ batch: PinApplyBatch) async throws {
        try await store.applyPinSyncBatchThrowing(batch.ops)
        // Rebuild after landing, not merely invalidate: §4.5 validates before baseline writes through cached
        // readers. False isKnownLocalPin results would make identities look dead and emit tombstones. A reread
        // error propagates after the batch committed; callers must distinguish landed-but-unreadable from
        // unapplied. Readers remain invalid until the next successful allPins.
        try rebuildCache()
    }

    /// Narrow favicon backfill write (§8.2 / Task 10), one background transaction per round. Leave caches
    /// untouched: favicon is absent from PhiLocalPin and invisible to diff/cursors.
    func setFavicon(_ writes: [(guid: String, data: Data)]) async throws {
        try await store.updateTabFaviconsThrowing(
            writes.map { (guid: $0.guid, favicon: $0.data) })
    }

    /// Scope migration passes both preferred arguments exactly as UI (§7.1). Preferred source ordering
    /// controls merged pin values/order, so omitting them could diverge local and remote application.
    func changeScope(to scope: PinnedTabScope,
                     preferredProfileId: String?,
                     preferredSpaceId: String?) async throws {
        try await store.changePinnedTabScope(to: scope,
                                             preferredProfileId: preferredProfileId,
                                             preferredSpaceId: preferredSpaceId)
        // Migration recreated physical rows with new GUIDs/owners, invalidating this snapshot. Clear without
        // rereading: §7.3 skips publication in the scope-convergence round, so no readers need another fetch.
        invalidateCache()
    }

    // MARK: - Private helpers

    /// Clear rather than retain: isKnownLocalPin must not silently report stale state.
    private func invalidateCache() {
        cachedRows = []
        cachedIdentityPairs = []
        cachedFullStoreRows = []
        snapshotIsLoaded = false
    }

    /// Nonthrowing reader precondition. False forces an absent default its signature cannot distinguish from
    /// unknown; assert in DEBUG to expose misuse before it becomes mass tombstones.
    private func requireLoadedSnapshot() -> Bool {
        if !snapshotIsLoaded {
            assertionFailure("read the pin snapshot before a successful allPins()/apply()")
        }
        return snapshotIsLoaded
    }

    /// Clear caches first and throw on every failure (R-exec-3).
    private func rebuildCache() throws {
        invalidateCache()
        guard let context = store.getMainContext() else {
            AppLogError("[phi-sync] pin snapshot failed: no main context")
            throw LocalStoreWriteError.storeUnavailable
        }
        let fetched: LocalStore.PinSyncFetch
        do {
            fetched = try store.pinSyncFetch(in: context)
        } catch {
            // R12: log only type/domain/code, never row content.
            AppLogError("[phi-sync] pin snapshot fetch failed: \(PhiSyncLog.describe(error))")
            throw error
        }

        // Local split links use physical GUIDs, while wire links use lineage. Build the translation from the
        // same models without another query.
        var lineageByGuid: [String: String] = [:]
        for model in fetched.nonDormant {
            lineageByGuid[model.guid] = model.pinLineageId ?? model.guid
        }

        let rows = fetched.active.map { Self.project($0, lineageByGuid: lineageByGuid) }
        // Replace both indices and snapshot together with no intermediate mismatch.
        cachedRows = rows
        // Index full identity: lineage alone would falsely confirm a missing Space-X row when the same lineage
        // remains in Space Y (R-M3-3-15).
        cachedIdentityPairs = Set(rows.map {
            PinKind.lineageKey($0.lineageId) + ":" + PinKind.localOwnerKey($0)
        })
        // Return domain rows so callers derive identity through the same PinKind.identity helper as snapshots.
        // Each row protects only its own lineage/owner pair (R-exec-11).
        cachedFullStoreRows = fetched.nonDormant.map {
            Self.project($0, lineageByGuid: lineageByGuid)
        }
        snapshotIsLoaded = true
    }

    /// Value snapshots, never model objects: SwiftData refreshes instances in place and object deduplication
    /// would swallow edits (§4.8). Preserve raw lineage bytes (P11); normalize only at comparison boundaries
    /// to avoid false read-time changes.
    private static func project(_ model: TabDataModel,
                                lineageByGuid: [String: String]) -> PhiLocalPin {
        PhiLocalPin(lineageId: model.pinLineageId ?? model.guid,
                    guid: model.guid,
                    spaceId: model.spaceId,
                    profileId: model.profileId ?? model.profile?.profileId,
                    index: model.index,
                    title: model.title,
                    url: model.url,
                    splitPartnerLineageId: model.splitPartnerGuid.flatMap { lineageByGuid[$0] },
                    source: model.source,
                    createdDate: model.createdDate,
                    contentUpdatedDate: model.contentUpdatedDate,
                    isDormant: model.isPinnedTabDormant)
    }
}

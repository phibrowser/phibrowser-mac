import CryptoKit
import Foundation
import XCTest
@testable import Phi

// MARK: - Fakes

/// In-memory PhiBookmarkLocalAccess, following FakePhiSpaceAccess: a top-level
/// type recording calls in an enum array. apply actually mutates rows (V10),
/// because many later cases assert row values immediately after application.
@MainActor
final class FakeBookmarkAccess: PhiBookmarkLocalAccess {
    enum Call: Equatable {
        case allBookmarks
        case allSyncIds
        case siblings(parent: String?, space: String)
        case apply(opCount: Int)
        case clearAllSyncIds
    }

    var rows: [PhiLocalBookmark]
    var importingSpaceIds: Set<String> = []
    /// Make both reads throw on every call (R-exec-3), without resetting. Engine tests
    /// assert that a read failure skips the whole section; a one-shot error lets later reads succeed.
    var readError: Error?
    /// Identities with local rows outside the snapshot, under orphan or duplicate roots
    /// (R-exec-4). allBookmarks excludes them; allSyncIds includes them to prevent false deletions.
    var orphanedSyncIds: Set<String> = []
    /// Match production snapshot validity: the three cache readers are meaningful only
    /// after this round's last successful allBookmarks or apply; otherwise return absent,
    /// and allSyncIds throws. Without this contract, Task 6's post-apply verification
    /// would succeed in the fake but report every row absent in production (G1 / G4).
    private(set) var snapshotIsLoaded = false
    /// The next apply throws storeUnavailable, resets the flag, and changes no rows.
    var failApplyOnce = false
    /// The next apply throws this error, resets it, and changes no rows. Unlike the
    /// storeUnavailable-only failApplyOnce, this can inject §4.5's import-lock,
    /// folderNotEmpty, and rowAlreadyMapped failures, which require opposite responses.
    var applyErrorOnce: Error?
    /// apply succeeds without changing rows, modeling silent guards from before Task 2a.
    var applyLandsNothingSilently = false
    /// Make clearAllSyncIds throw for Task 9a ordering tests.
    var failClearSyncIds = false
    private(set) var calls: [Call] = []
    /// Record the latest apply ops even when it throws: ordering assertions check
    /// what the engine submitted, not what persisted.
    private(set) var lastAppliedOps: [BookmarkApplyOp] = []

    init(rows: [PhiLocalBookmark] = []) {
        self.rows = rows
    }

    /// Order by (spaceId, parentGuid, index, guid), matching §4.8 and allPins. Engine
    /// commit-order and index-projection tests must receive production ordering to avoid
    /// false results. Parentless rows precede parented rows within a Space.
    /// Start a new round by invalidating the snapshot, allowing tests of R-exec-3's three invalid states.
    func beginRound() {
        snapshotIsLoaded = false
    }

    func allBookmarks() throws -> [PhiLocalBookmark] {
        calls.append(.allBookmarks)
        if let readError { throw readError }
        snapshotIsLoaded = true
        return rows.sorted {
            ($0.spaceId, $0.parentGuid ?? "", $0.index, $0.guid)
                < ($1.spaceId, $1.parentGuid ?? "", $1.index, $1.guid)
        }
    }

    /// Return the existing fetched snapshot without fetching or recording a call, like
    /// isKnownLocalBookmark and localIsFolder. CASE 0.3 compares calls exactly. Order
    /// matches allBookmarks. Return nil before a read, matching production: an empty
    /// array would replace the round's local projection and erase its outbound snapshot.
    func cachedBookmarks() -> [PhiLocalBookmark]? {
        guard snapshotIsLoaded else { return nil }
        return rows.sorted {
            ($0.spaceId, $0.parentGuid ?? "", $0.index, $0.guid)
                < ($1.spaceId, $1.parentGuid ?? "", $1.index, $1.guid)
        }
    }

    /// Group the existing fetched rows in memory without recording another allBookmarks
    /// call or filtering: §4.10's index projection needs unfiltered siblings.
    func siblings(ofParent parentGuid: String?, inSpaceId spaceId: String) -> [PhiLocalBookmark] {
        calls.append(.siblings(parent: parentGuid, space: spaceId))
        guard snapshotIsLoaded else { return [] }
        return rows
            .filter { $0.spaceId == spaceId && $0.parentGuid == parentGuid }
            .sorted { ($0.index, $0.guid) < ($1.index, $1.guid) }
    }

    /// Combine snapshot identities with excluded ones. Production uses an unfiltered
    /// fetch; orphanedSyncIds models the same result because fake rows have no root concept.
    func allSyncIds() throws -> Set<String> {
        calls.append(.allSyncIds)
        if let readError { throw readError }
        // Like production, use the snapshot fetch's unfiltered result. Throw before a
        // successful read this round instead of returning an empty set that falsely deletes a subtree.
        guard snapshotIsLoaded else { throw LocalStoreWriteError.storeUnavailable }
        return Set(rows.compactMap(\.syncId)).union(orphanedSyncIds)
    }

    func isKnownLocalBookmark(_ guid: String) -> Bool {
        guard snapshotIsLoaded else { return false }
        return rows.contains { $0.guid == guid }
    }

    /// Production reads dataType from the fetched grouping cache; use the same rows
    /// here so both implementations return nil for missing rows.
    func localIsFolder(guid: String) -> Bool? {
        guard snapshotIsLoaded else { return nil }
        return rows.first { $0.guid == guid }?.isFolder
    }

    func isImporting(intoSpaceId spaceId: String) -> Bool {
        importingSpaceIds.contains(spaceId)
    }

    func apply(_ batch: BookmarkApplyBatch) async throws {
        calls.append(.apply(opCount: batch.ops.count))
        lastAppliedOps = batch.ops
        if failApplyOnce {
            failApplyOnce = false
            throw LocalStoreWriteError.storeUnavailable
        }
        if let applyErrorOnce {
            self.applyErrorOnce = nil
            throw applyErrorOnce
        }
        // Match production refuseIfImporting in LocalStore+Bookmark.swift: reject the entire
        // batch if any operation's Space is importing. Without this fail-closed behavior,
        // CASE 6.10c-2 cannot test splitting operations by Space.
        if let locked = batch.ops.compactMap(spaceId(of:)).first(where: importingSpaceIds.contains) {
            throw LocalStoreWriteError.spaceImporting(spaceId: locked)
        }
        // Claim an identity only once, matching production's nil-or-equal syncId guard.
        // A different identity rejects the whole batch without changes; overwriting it
        // would make the old account identity look locally deleted and publish a tombstone.
        //
        // This scan examines rows before any op, covering identities from earlier batches
        // or the round snapshot. The real store checks sequentially, so a second claim
        // in one batch sees the first; the fake is looser. CASE 6b.13's final row-identity
        // assertion covers double claims within a batch rather than this scan.
        for op in batch.ops {
            guard case .claim(let guid, let syncId) = op,
                  let existing = rows.first(where: { $0.guid == guid })?.syncId,
                  existing != syncId else { continue }
            throw LocalStoreWriteError.rowAlreadyMapped
        }
        // Production rereads after successful application, enabling same-round §4.5
        // verification (G1). A thrown write skips this reread and preserves the old snapshot.
        snapshotIsLoaded = true
        guard !applyLandsNothingSilently else { return }
        for op in batch.ops { land(op) }
    }

    /// Task 10 backfill (row, bytes) pairs flattened in arrival order.
    private(set) var faviconWrites: [(guid: String, data: Data)] = []
    /// Count setFavicon calls: flattened row counts alone cannot prove CASE 10.11's
    /// one-write-per-round invariant.
    private(set) var faviconWriteCalls = 0
    /// The next setFavicon throws, resets the flag, and writes nothing.
    var failSetFaviconOnce = false

    /// Exclude backfill from calls, which records sync application. Backfill deliberately
    /// uses another path; mixing it in would obscure zero-apply assertions.
    func setFavicon(_ writes: [(guid: String, data: Data)]) async throws {
        faviconWriteCalls += 1
        if failSetFaviconOnce {
            failSetFaviconOnce = false
            throw LocalStoreWriteError.storeUnavailable
        }
        faviconWrites.append(contentsOf: writes)
    }

    func clearAllSyncIds() async throws {
        calls.append(.clearAllSyncIds)
        if failClearSyncIds { throw LocalStoreWriteError.storeUnavailable }
        for index in rows.indices { rows[index].syncId = nil }
    }

    /// Resolve an operation's Space: create/move carry their target; other operations
    /// use the named row's current Space.
    private func spaceId(of op: BookmarkApplyOp) -> String? {
        switch op {
        case .create(let row): return row.spaceId
        case .move(_, _, let spaceId, _): return spaceId
        case .claim(let guid, _), .update(let guid, _), .delete(let guid):
            return rows.first { $0.guid == guid }?.spaceId
        }
    }

    /// Delete only the named row, without cascading. BookmarkApplyBatch already orders
    /// every subtree deletion child-first; cascading would make delete-op and applied-row counts differ.
    private func land(_ op: BookmarkApplyOp) {
        switch op {
        case .claim(let guid, let syncId):
            guard let index = rows.firstIndex(where: { $0.guid == guid }) else { return }
            rows[index].syncId = syncId
        case .create(let row):
            rows.append(row)
        case .move(let guid, let parentGuid, let spaceId, let position):
            guard let index = rows.firstIndex(where: { $0.guid == guid }) else { return }
            rows[index].parentGuid = parentGuid
            rows[index].spaceId = spaceId
            rows[index].index = position
        case .update(let guid, let fields):
            guard let index = rows.firstIndex(where: { $0.guid == guid }) else { return }
            // Outer some means modify the field. Local title/URL are nonoptional, so inner
            // nil clears title to empty but leaves URL unchanged; a bookmark cannot lose its URL.
            if let title = fields.title { rows[index].title = title ?? "" }
            if let url = fields.url, let url { rows[index].url = url }
            if let secondaryUrl = fields.secondaryUrl { rows[index].secondaryUrl = secondaryUrl }
            if let secondaryTitle = fields.secondaryTitle {
                rows[index].secondaryTitle = secondaryTitle
            }
        case .delete(let guid):
            rows.removeAll { $0.guid == guid }
        }
    }
}

/// In-memory PhiPinnedTabLocalAccess with the same apply contract as FakeBookmarkAccess.
@MainActor
final class FakePinAccess: PhiPinnedTabLocalAccess {
    enum Call: Equatable {
        case allPins
        case allPinRows
        case apply(opCount: Int)
        case changeScope(PinnedTabScope)
    }

    var scope: PinnedTabScope
    var account: PinnedTabScope?
    var rows: [PhiLocalPin]
    /// Both reads throw persistently (R-exec-3), without resetting. Tests must verify
    /// that a read failure skips the whole section; one-shot failure permits a later read to succeed.
    var readError: Error?
    /// Local rows outside the snapshot: backup rows retained outside the active scope
    /// after migration (R-exec-4). allPins excludes them; allPinRows includes them to
    /// prevent false deletions. These are rows, not lineages (R-exec-11): each protects
    /// its own (lineage, owner) identity, so spaceId/profileId must be accurate.
    var outOfScopeRows: [PhiLocalPin] = []
    /// Match production: isKnownLocalPin is valid only after this round's successful
    /// allPins or apply; otherwise report absent. allPinRows throws before that point.
    private(set) var snapshotIsLoaded = false
    /// The next apply throws storeUnavailable, resets the flag, and changes no rows.
    var failApplyOnce = false
    private(set) var calls: [Call] = []
    private(set) var lastAppliedOps: [PinApplyOp] = []

    init(scope: PinnedTabScope, account: PinnedTabScope? = nil, rows: [PhiLocalPin] = []) {
        self.scope = scope
        self.account = account
        self.rows = rows
    }

    func currentScope() -> PinnedTabScope { scope }

    /// Script a mid-round scope migration (R-exec-12): on the specified accountScope
    /// read, capture the return value before running run in place, then clear the hook.
    /// Task 8's detached applyAccountPinnedTabScope can migrate between initial sampling
    /// and application; this reproduces that instant.
    ///
    /// Hook accountScope, not currentScope: initial sampling reads allPins, currentScope,
    /// then accountScope. Only the last hook preserves both pre-migration scope values.
    /// Earlier hooks yield an inconsistent initial pair already rejected by §7.3,
    /// which would not exercise this fix. beginRound is read 1; each rescanScopes adds one.
    var midRoundMigration: (onAccountScopeRead: Int, run: @MainActor (FakePinAccess) -> Void)?
    private(set) var accountScopeReads = 0

    func accountScope() -> PinnedTabScope? {
        accountScopeReads += 1
        let answer = account
        if let hook = midRoundMigration, hook.onAccountScopeRead == accountScopeReads {
            midRoundMigration = nil
            hook.run(self)
        }
        return answer
    }

    /// Invalidate the snapshot for a new round to construct R-exec-3's three invalid states.
    func beginRound() {
        snapshotIsLoaded = false
    }

    /// All nondormant rows ordered by (ownerKey, index, guid), without choosing representatives.
    func allPins() throws -> [PhiLocalPin] {
        calls.append(.allPins)
        if let readError { throw readError }
        snapshotIsLoaded = true
        return rows
            .filter { !$0.isDormant }
            .sorted { (Self.ownerKey($0), $0.index, $0.guid) < (Self.ownerKey($1), $1.index, $1.guid) }
    }

    /// Combine snapshot and out-of-scope rows. Production uses the same fetch before
    /// scope filtering; outOfScopeRows models that because the fake's rows lack an alternate-scope concept.
    func allPinRows() throws -> [PhiLocalPin] {
        calls.append(.allPinRows)
        if let readError { throw readError }
        // Match production: throw before a successful round read rather than return an
        // empty array that falsely classifies every pin as deleted.
        guard snapshotIsLoaded else { throw LocalStoreWriteError.storeUnavailable }
        return (rows + outOfScopeRows).filter { !$0.isDormant }
    }

    /// Return the cached fetched snapshot without another fetch or recorded call,
    /// as in FakeBookmarkAccess.cachedBookmarks. Filtering and ordering match allPins.
    func cachedPins() -> [PhiLocalPin]? {
        guard snapshotIsLoaded else { return nil }
        return rows
            .filter { !$0.isDormant }
            .sorted { (Self.ownerKey($0), $0.index, $0.guid) < (Self.ownerKey($1), $1.index, $1.guid) }
    }

    /// Normalize both sides with PinKind.lineageKey (P11), matching production: wire
    /// lineage is lowercase while rows may be uppercase. Compare the full (lineage, ownerKey)
    /// identity; lineage alone falsely finds (L, spaceX) when only (L, spaceY) remains.
    /// A nil ownerKey means local-owner lookup failed, so no matching local identity can exist.
    func isKnownLocalPin(_ lineageId: String, ownerKey: String?) -> Bool {
        guard snapshotIsLoaded, let ownerKey else { return false }
        let wanted = PinKind.lineageKey(lineageId)
        return rows.contains {
            PinKind.lineageKey($0.lineageId) == wanted && Self.ownerKey($0) == ownerKey
        }
    }

    func apply(_ batch: PinApplyBatch) async throws {
        calls.append(.apply(opCount: batch.ops.count))
        lastAppliedOps = batch.ops
        if failApplyOnce {
            failApplyOnce = false
            throw LocalStoreWriteError.storeUnavailable
        }
        // Production rereads after successful application for same-round §4.5 verification.
        // Thrown writes skip the reread and preserve the old snapshot.
        snapshotIsLoaded = true
        for op in batch.ops { land(op) }
    }

    /// Task 10 backfill write API, with the same semantics as FakeBookmarkAccess.
    private(set) var faviconWrites: [(guid: String, data: Data)] = []
    private(set) var faviconWriteCalls = 0
    var failSetFaviconOnce = false

    func setFavicon(_ writes: [(guid: String, data: Data)]) async throws {
        faviconWriteCalls += 1
        if failSetFaviconOnce {
            failSetFaviconOnce = false
            throw LocalStoreWriteError.storeUnavailable
        }
        faviconWrites.append(contentsOf: writes)
    }

    func changeScope(to scope: PinnedTabScope,
                     preferredProfileId: String?,
                     preferredSpaceId: String?) async throws {
        calls.append(.changeScope(scope))
        self.scope = scope
        // Migration rebuilt all physical rows, invalidating the round snapshot. Production
        // also clears it here without rereading.
        snapshotIsLoaded = false
    }

    /// Local equivalent of ownerKey in phi-pin:<lineage>:<ownerKey>: spaceId for Space
    /// scope, profileId for Profile scope, and literal app for App scope.
    private static func ownerKey(_ pin: PhiLocalPin) -> String {
        pin.spaceId ?? pin.profileId ?? "app"
    }

    private func land(_ op: PinApplyOp) {
        switch op {
        case .create(let row):
            rows.append(row)
        case .relineage(let guid, let newLineageId):
            guard let index = rows.firstIndex(where: { $0.guid == guid }) else { return }
            rows[index].lineageId = newLineageId
        case .move(let guid, let position):
            guard let index = rows.firstIndex(where: { $0.guid == guid }) else { return }
            rows[index].index = position
        case .update(let guid, let fields):
            guard let index = rows.firstIndex(where: { $0.guid == guid }) else { return }
            if let title = fields.title { rows[index].title = title ?? "" }
            if let url = fields.url, let url { rows[index].url = url }
            if let partner = fields.splitPartnerLineageId {
                rows[index].splitPartnerLineageId = partner
            }
        case .delete(let guid):
            rows.removeAll { $0.guid == guid }
        }
    }
}

/// In-memory PhiURLRuleLocalAccess (Task 8), following FakeBookmarkAccess: apply
/// mutates rows and densely normalizes both buckets so Task 6 sees production results.
/// readError persists (R-exec-3). snapshotIsLoaded/beginRound match production: both
/// cache readers are valid only after this round's last successful read or apply.
@MainActor
final class FakeURLRuleAccess: PhiURLRuleLocalAccess {
    enum Call: Equatable {
        case allURLRules
        case allURLRulesIncludingDeleted
        case siblings(space: String)
        case liveOwners(count: Int)
        case apply(opCount: Int)
        /// Task 6: explicit routing-table refresh after application commits (§6.6 / R-M3-4a-34).
        case refreshRoutingTable
        /// 8b-1: count the two in-place update APIs so CASE M-18 can prove they ran (R-M3-4a-62).
        case notePersistedClaims(count: Int)
        case noteDeletedRows(count: Int)
        /// 8b-4 / §8.4.5: clear (a) once per identity, and (b) once per transaction, with no call for an empty set.
        case clearPendingLocalEdit(syncId: String)
        case clearPendingLocalEditIfUnchanged(count: Int)
    }

    /// Includes soft-deleted rows; each read filters its own domain.
    var rows: [PhiLocalURLRule]
    /// Both reads and liveOwners throw on every call without resetting.
    var readError: Error?
    private(set) var snapshotIsLoaded = false
    /// The next apply throws storeUnavailable, resets the flag, and changes no rows.
    var failApplyOnce = false
    /// The next apply throws this error, clears it, and changes no rows.
    var applyErrorOnce: Error?
    private(set) var calls: [Call] = []
    /// Latest apply ops, including calls that throw.
    private(set) var lastAppliedOps: [URLRuleSyncOp] = []
    /// Task 9 exit 1: hardDeleteURLRule calls in order, including missing-row calls.
    private(set) var hardDeleteCalls: [String] = []
    /// Task 9 exit 2: every cutoff passed to purgeSoftDeletedURLRules.
    private(set) var purgeCalls: [Date] = []
    /// Both exits throw persistently without resetting.
    var deleteError: Error?
    /// 8b-2 / R-M3-4a-100 (CASE M-36): run once before apply's write-plus-tail-hook
    /// segment to inject a real local Save through applyURLRuleEditsThrowing between
    /// pre-pass and transaction. Never mutate rows or cursors directly. Production has
    /// this window because main-actor pre-pass queues through performBackgroundWriteAndWaitThrowing
    /// before the write transaction. This hook is fake-only; leave the production protocol unchanged.
    var beforeLandingTransaction: (@MainActor () async -> Void)?
    /// M2 ops returned by the latest apply tail hook, or an empty array without a hook.
    private(set) var lastMergeOps: [URLRuleSyncOp] = []
    /// 8b-4 / CASE M-7e: the next clearPendingLocalEdit throws storeUnavailable once
    /// without writes, matching §8.4.5 row 7: log R12 and let (b) repair next round.
    var failNextClearPendingLocalEdit = false
    /// 8b-4 / CASE M-7e (R-M3-4a-91 / ruling 14): run once immediately before
    /// clearPendingLocalEditIfUnchanged's transaction, injecting a real local Save
    /// through applyEditorSave between decision and write, never direct row mutation.
    ///
    /// Keep this hook in the fake: registration closures and engine hold only Set<String>,
    /// so a hook there cannot access entries or test the actual decision/write window.
    /// Leave the production protocol unchanged.
    var beforeClearPendingLocalEditIfUnchanged: (@MainActor () async -> Void)?
    /// Latest identity-to-baseline table passed to clearPendingLocalEditIfUnchanged.
    private(set) var lastClearEntries: [String: RuleProjection] = [:]

    init(rows: [PhiLocalURLRule] = []) {
        self.rows = rows
    }

    /// Invalidate the snapshot at the start of a new round.
    func beginRound() {
        snapshotIsLoaded = false
    }

    /// Live rows in production order: (spaceId, sortOrder, id).
    func allURLRules() throws -> [PhiLocalURLRule] {
        calls.append(.allURLRules)
        if let readError { throw readError }
        snapshotIsLoaded = true
        return Self.ordered(rows.filter { $0.deletedDate == nil })
    }

    /// Live plus soft-deleted rows in the same order.
    func allURLRulesIncludingDeleted() throws -> [PhiLocalURLRule] {
        calls.append(.allURLRulesIncludingDeleted)
        if let readError { throw readError }
        snapshotIsLoaded = true
        return Self.ordered(rows)
    }

    /// Group this page's snapshot by spaceId, excluding soft-deleted rows (R-M3-4a-51)
    /// without eligibility filtering.
    func siblings(inSpaceId spaceId: String) -> [PhiLocalURLRule] {
        calls.append(.siblings(space: spaceId))
        guard snapshotIsLoaded else { return [] }
        return Self.ordered(rows.filter { $0.spaceId == spaceId && $0.deletedDate == nil })
    }

    /// Address by syncId, not id, over the live-row domain shared with allURLRules.
    func isKnownLocalURLRule(_ syncId: String) -> Bool {
        guard snapshotIsLoaded else { return false }
        return rows.contains { $0.syncId == syncId && $0.deletedDate == nil }
    }

    /// Production fetches independently of the page cache, so ignore snapshotIsLoaded.
    /// Fill claimed only; Task 6's registration closure adds owners through OwnedOwnerMaps.
    func liveOwners(_ candidates: Set<String>) throws -> OwnedLiveRows {
        calls.append(.liveOwners(count: candidates.count))
        if let readError { throw readError }
        let live = Set(rows.filter { $0.deletedDate == nil }.compactMap(\.syncId))
        return OwnedLiveRows(claimed: candidates.intersection(live), owners: [:])
    }

    /// Run even with empty ops and only a tail hook: M2 must run on pages applying
    /// no rules (8b-2 / R-M3-4a-56). Match production order: apply ops, tail hook, dense normalization.
    @discardableResult
    func apply(_ batch: URLRuleApplyBatch) async throws -> URLRuleBatchOutcome {
        calls.append(.apply(opCount: batch.ops.count))
        lastAppliedOps = batch.ops
        lastMergeOps = []
        if failApplyOnce {
            failApplyOnce = false
            throw LocalStoreWriteError.storeUnavailable
        }
        if let applyErrorOnce {
            self.applyErrorOnce = nil
            throw applyErrorOnce
        }
        // R-M3-4a-100 / CASE M-36 injection: pre-pass has finished, but application has not started.
        if let beforeLandingTransaction {
            await beforeLandingTransaction()
        }
        // Match LocalStore.rekeyURLRuleBody's two re-key guards and collision check.
        // Validate the entire batch before mutating rows: the fake has no transaction,
        // so a mid-batch throw would violate §5.5's no-partial-application contract.
        for op in batch.ops {
            guard case .rekey(let localId, let to, _) = op else { continue }
            guard let row = rows.first(where: { $0.id == localId }), row.deletedDate == nil else {
                throw LocalStoreWriteError.rowNotFound
            }
            if row.syncId != to, rows.contains(where: { $0.syncId == to && $0.id != localId }) {
                throw LocalStoreWriteError.rowAlreadyMapped
            }
        }
        var touchedBuckets: Set<String> = []
        var outcome = URLRuleBatchOutcome()
        // 8b-3 / R-M3-4a-102: recheck unchanged source only for pair α, using the
        // production criterion: does this batch contain a delete for the transfer's identity?
        var alphaSources: Set<String> = []
        for op in batch.ops {
            if case .delete(let syncId) = op { alphaSources.insert(syncId) }
        }
        for op in batch.ops {
            land(op, touchedBuckets: &touchedBuckets, outcome: &outcome,
                 alphaSources: alphaSources)
        }
        // Pass the current projection including soft-deleted rows to the tail hook for
        // addressing. Run it before dense normalization or the loser's former bucket retains a gap.
        if let mergeTail = batch.mergeTail {
            let result = mergeTail.evaluate(Self.ordered(rows))
            lastMergeOps = result.ops
            for op in result.ops {
                land(op, touchedBuckets: &touchedBuckets, outcome: &outcome,
                     alphaSources: alphaSources)
            }
            touchedBuckets.formUnion(result.touchedBuckets)
            outcome.collapsed = result.collapsed
            outcome.mergeChangedRouting = result.changedRouting
        }
        for bucket in touchedBuckets {
            densify(bucket)
        }
        // Production rereads at the end to enable same-round post-apply verification.
        snapshotIsLoaded = true
        return outcome
    }

    /// Record one ordered call; CASE U-24 requires it after apply, once per page.
    func refreshRoutingTableAfterLanding() {
        calls.append(.refreshRoutingTable)
    }

    // MARK: 8b-1: D30's four read queries and two in-place update APIs

    /// All four queries use rows and share URLRuleSignatureQueries with production,
    /// keeping one set of criteria. Ignore snapshotIsLoaded because M-28/M-29 call the fake directly.
    func signatureIndex(resolve: OwnerResolver) -> [RuleSignature: [PhiLocalURLRule]] {
        URLRuleSignatureQueries.signatureIndex(rows: rows, resolve: resolve)
    }

    func pendingLocalEditIdentities(resolve: OwnerResolver) -> Set<String> {
        URLRuleSignatureQueries.pendingLocalEditIdentities(rows: rows, resolve: resolve)
    }

    func unpublishedIdentities(table: PhiOwnedItemTable, resolve: OwnerResolver) -> Set<String> {
        URLRuleSignatureQueries.unpublishedIdentities(rows: rows, table: table, resolve: resolve)
    }

    func mergePartners(table: PhiOwnedItemTable, resolve: OwnerResolver,
                       tombstonesThisPage: Set<String>) -> [String: String] {
        URLRuleSignatureQueries.mergePartners(rows: rows, table: table, resolve: resolve,
                                              tombstonesThisPage: tombstonesThisPage)
    }

    /// Map local row id to new syncId, opposite to bookmarks. apply already changed
    /// rows; this is an idempotent follow-up write that records one call.
    func notePersistedClaims(_ claimed: [String: String]) {
        calls.append(.notePersistedClaims(count: claimed.count))
        for index in rows.indices {
            if let syncId = claimed[rows[index].id] { rows[index].syncId = syncId }
        }
    }

    func noteDeletedRows(_ syncIds: Set<String>) {
        calls.append(.noteDeletedRows(count: syncIds.count))
        rows.removeAll { row in
            guard let syncId = row.syncId else { return false }
            return syncIds.contains(syncId)
        }
    }

    // MARK: 8b-4: Both flag-clearing paths from §8.4.5

    /// Clear (a), matching LocalStore.clearPendingLocalEditBody: address including
    /// soft-deleted rows, clear a nonnil mergePartnerSyncId without redundant writes,
    /// guard pendingLocalEdit, compute the projection with the production function,
    /// and clear the flag only if every unit matches. Keep the same order and criteria
    /// for all three actions even though the fake has no transaction.
    @discardableResult
    func clearPendingLocalEdit(syncId: String,
                               ifProjectionEquals confirmed: RuleProjection) async throws -> Bool {
        calls.append(.clearPendingLocalEdit(syncId: syncId))
        if failNextClearPendingLocalEdit {
            failNextClearPendingLocalEdit = false
            throw LocalStoreWriteError.storeUnavailable
        }
        guard let index = rows.firstIndex(where: { $0.syncId == syncId }) else { return false }
        if rows[index].mergePartnerSyncId != nil { rows[index].mergePartnerSyncId = nil }
        guard rows[index].pendingLocalEdit else { return false }
        let current = URLRuleKind.clearingProjection(of: rows[index])
        guard URLRuleKind.clearingProjectionMatches(row: current, confirmed: confirmed) else {
            return false
        }
        rows[index].pendingLocalEdit = false
        return true
    }

    /// Clear (b), matching production with the M-7e hook. Never change mergePartnerSyncId.
    func clearPendingLocalEditIfUnchanged(entries: [String: RuleProjection]) async throws {
        calls.append(.clearPendingLocalEditIfUnchanged(count: entries.count))
        lastClearEntries = entries
        // The real interval between deciding and writing (ruling 14).
        if let beforeClearPendingLocalEditIfUnchanged {
            await beforeClearPendingLocalEditIfUnchanged()
        }
        for syncId in entries.keys.sorted() {
            guard let confirmed = entries[syncId],
                  let index = rows.firstIndex(where: { $0.syncId == syncId }) else { continue }
            guard rows[index].pendingLocalEdit else { continue }
            let current = URLRuleKind.clearingProjection(of: rows[index])
            guard URLRuleKind.clearingProjectionMatches(row: current, confirmed: confirmed) else {
                continue
            }
            rows[index].pendingLocalEdit = false
        }
    }

    /// Exit 1: hard-delete by syncId, including live and soft-deleted rows. Production
    /// also ignores deletedDate; missing rows are no-ops.
    func hardDeleteURLRule(syncId: String) async throws {
        hardDeleteCalls.append(syncId)
        if let deleteError { throw deleteError }
        let buckets = Set(rows.filter { $0.syncId == syncId }.map(\.spaceId))
        rows.removeAll { $0.syncId == syncId }
        for bucket in buckets { densify(bucket) }
    }

    /// Exit 2: use the row's deletedDate, independent of cursors; preserve soft-deleted rows without syncId.
    func purgeSoftDeletedURLRules(olderThan cutoff: Date) async throws -> Int {
        purgeCalls.append(cutoff)
        if let deleteError { throw deleteError }
        let expired = rows.compactMap { row -> String? in
            guard let deletedDate = row.deletedDate, deletedDate < cutoff else { return nil }
            return row.syncId
        }
        for syncId in expired {
            rows.removeAll { $0.syncId == syncId }
        }
        return expired.count
    }

    /// Editor-semantic local Save, equivalent to LocalStore.applyURLRuleEditsBody
    /// steps 4/9: compare all three content members; if any differ, write changed fields,
    /// contentUpdatedDate, and pendingLocalEdit=true. If all match, write and flag nothing.
    ///
    /// Tests must not mutate rows directly. With no backing LocalStore, this is the fake's
    /// real-user-write API for R-M3-4a-100 / CASE M-36 injection. Leave cursors untouched:
    /// this Save has not reached the account.
    func applyEditorSave(syncId: String, host: String? = nil, pathPrefix: String?? = nil,
                         ask: Bool? = nil, at contentUpdatedDate: Date) {
        guard let index = rows.firstIndex(where: { $0.syncId == syncId }),
              rows[index].deletedDate == nil else { return }
        var changed = false
        if let host {
            let normalized = LocalStore.normalizedHost(host)
            if rows[index].host != normalized {
                rows[index].host = normalized
                changed = true
            }
        }
        if let pathPrefix {
            let normalized = LocalStore.normalizedPathPrefix(pathPrefix)
            if rows[index].pathPrefix != normalized {
                rows[index].pathPrefix = normalized
                changed = true
            }
        }
        if let ask, rows[index].askBeforeRouting != ask {
            rows[index].askBeforeRouting = ask
            changed = true
        }
        guard changed else { return }
        rows[index].contentUpdatedDate = contentUpdatedDate
        rows[index].pendingLocalEdit = true
    }

    /// Retargeting half of the same API, matching steps 5/9: if the target changes,
    /// write spaceId, targetUpdatedDate, and pendingLocalEdit=true; otherwise write
    /// and flag nothing. applyEditorDelete handles deletedIds.
    func applyEditorRetarget(syncId: String, toSpaceId: String, at targetUpdatedDate: Date) {
        guard let index = rows.firstIndex(where: { $0.syncId == syncId }),
              rows[index].deletedDate == nil, rows[index].spaceId != toSpaceId else { return }
        rows[index].spaceId = toSpaceId
        rows[index].targetUpdatedDate = targetUpdatedDate
        rows[index].pendingLocalEdit = true
    }

    /// Pure-drag half of the API, steps 8/9: move the row to sortOrder in its bucket,
    /// write dense indexes 0...n-1, and flag only the dragged row. Other rows' renumbering
    /// is a step-8 side effect outside upsertedIds, so step 9 leaves their flags alone.
    /// Neither timestamp changes (§4.3 rule 4). The 8b-4 fix-round-1 / ruling-3 probe
    /// needs this because flag clearing compares three merge units, including rank;
    /// applyEditorSave cannot model unchanged values with a changed position.
    func applyEditorReorder(syncId: String, toSortOrder: Int) {
        guard let index = rows.firstIndex(where: { $0.syncId == syncId }),
              rows[index].deletedDate == nil else { return }
        let bucket = rows[index].spaceId
        let movedId = rows[index].id
        var sequence = rows.filter { $0.spaceId == bucket && $0.deletedDate == nil && $0.id != movedId }
            .sorted { ($0.sortOrder, $0.id) < ($1.sortOrder, $1.id) }
        sequence.insert(rows[index], at: min(max(toSortOrder, 0), sequence.count))
        for (position, row) in sequence.enumerated() {
            guard let slot = rows.firstIndex(where: { $0.id == row.id }) else { continue }
            rows[slot].sortOrder = position
        }
        rows[index].pendingLocalEdit = true
    }

    /// Editor deletion set (step 7): soft-delete without touching pendingLocalEdit,
    /// since deletion is not an edit (R-M3-4a-69). The caller handles mergePartnerSyncId;
    /// M2 uses a softDelete op.
    func applyEditorDelete(syncId: String, at deletedDate: Date) {
        guard let index = rows.firstIndex(where: { $0.syncId == syncId }),
              rows[index].deletedDate == nil else { return }
        rows[index].deletedDate = deletedDate
    }

    private static func ordered(_ rows: [PhiLocalURLRule]) -> [PhiLocalURLRule] {
        rows.sorted { ($0.spaceId, $0.sortOrder, $0.id) < ($1.spaceId, $1.sortOrder, $1.id) }
    }

    /// Match LocalStore.applyURLRuleSyncBatchBody: address soft-deleted rows too.
    /// create/update/move write nine fields on a match or insert otherwise, clearing
    /// deletedDate/mergePartnerSyncId only for soft-deleted matches. Preserve live merge
    /// partners (upsertURLRuleBody, RR10-8). reorder writes only sortOrder; delete
    /// hard-deletes; rekey changes syncId by id and then applies optional values through
    /// update. Never change pendingLocalEdit.
    private func land(_ op: URLRuleSyncOp, touchedBuckets: inout Set<String>,
                      outcome: inout URLRuleBatchOutcome, alphaSources: Set<String>) {
        switch op {
        case .rekey(let localId, let syncId, let values):
            guard let index = rows.firstIndex(where: { $0.id == localId }) else { return }
            rows[index].syncId = syncId
            touchedBuckets.insert(rows[index].spaceId)
            if let values {
                land(.update(values), touchedBuckets: &touchedBuckets, outcome: &outcome,
                     alphaSources: alphaSources)
            }
        case .create(let values), .update(let values), .move(let values):
            let existing = rows.firstIndex { $0.syncId == values.syncId }
            let sourceBucket = existing.map { rows[$0].spaceId }
            // Match production: creation and soft-deleted restoration both enter the bucket; determine this before writing.
            let entersBucket = existing.map { rows[$0].deletedDate != nil } ?? true
            if let index = existing {
                rows[index].spaceId = values.spaceId
                rows[index].host = values.host
                rows[index].pathPrefix = values.pathPrefix
                rows[index].askBeforeRouting = values.askBeforeRouting
                rows[index].sortOrder = values.sortOrder
                rows[index].createdDate = values.createdDate
                rows[index].contentUpdatedDate = values.contentUpdatedDate
                rows[index].targetUpdatedDate = values.targetUpdatedDate
                if rows[index].deletedDate != nil {
                    rows[index].deletedDate = nil
                    rows[index].mergePartnerSyncId = nil
                }
            } else {
                rows.append(PhiLocalURLRule(id: UUID().uuidString, syncId: values.syncId,
                                            spaceId: values.spaceId, host: values.host,
                                            pathPrefix: values.pathPrefix,
                                            askBeforeRouting: values.askBeforeRouting,
                                            sortOrder: values.sortOrder, createdDate: values.createdDate,
                                            contentUpdatedDate: values.contentUpdatedDate,
                                            targetUpdatedDate: values.targetUpdatedDate,
                                            deletedDate: nil, pendingLocalEdit: false,
                                            mergePartnerSyncId: nil))
            }
            switch op {
            case .move:
                if let sourceBucket { touchedBuckets.insert(sourceBucket) }
                touchedBuckets.insert(values.spaceId)
            case .create:
                touchedBuckets.insert(values.spaceId)
            default:
                // For update, record the bucket only on insertion/restoration or, defensively, an actual target change.
                if entersBucket {
                    touchedBuckets.insert(values.spaceId)
                } else if let sourceBucket, sourceBucket != values.spaceId {
                    touchedBuckets.insert(sourceBucket)
                    touchedBuckets.insert(values.spaceId)
                }
            }
        case .reorder(let syncId, _, let sortOrder):
            guard let index = rows.firstIndex(where: { $0.syncId == syncId }) else { return }
            rows[index].sortOrder = sortOrder
            touchedBuckets.insert(rows[index].spaceId)
        case .delete(let syncId):
            // R-M3-4a-102: failed α recheck skips both transfer and same-identity delete.
            // Phase ordering ensures transfer has already populated the skip set.
            guard !outcome.deferredTombstones.contains(syncId) else { return }
            for row in rows where row.syncId == syncId {
                touchedBuckets.insert(row.spaceId)
            }
            rows.removeAll { $0.syncId == syncId }
        // 8b-3 / §8.4.4 edit transfer shares URLRuleKind.transferSourceUnchanged and
        // transferDecision with production; duplicate criteria would eventually disagree on the winner.
        case .transfer(let fromSyncId, let toSyncId, let source, let stamps):
            if alphaSources.contains(fromSyncId),
               !URLRuleKind.transferSourceUnchanged(
                   row: rows.first(where: { $0.syncId == fromSyncId }), source: source) {
                outcome.deferredTombstones.insert(fromSyncId)
                return
            }
            guard let index = rows.firstIndex(where: { $0.syncId == toSyncId }) else {
                outcome.transferSupersededByDelete += 1
                return
            }
            let decision = URLRuleKind.transferDecision(target: rows[index], source: source,
                                                        targetEffectiveStamps: stamps)
            if decision.writesContent {
                let normalized = LocalStore.normalizedRule(host: source.host,
                                                           pathPrefix: source.pathPrefix)
                rows[index].host = normalized.host
                rows[index].pathPrefix = normalized.pathPrefix
                rows[index].askBeforeRouting = source.askBeforeRouting
                rows[index].contentUpdatedDate = source.contentUpdatedDate
            }
            if decision.writesTarget, let spaceId = source.targetSpaceId {
                if rows[index].spaceId != spaceId {
                    touchedBuckets.insert(rows[index].spaceId)
                    rows[index].spaceId = spaceId
                    touchedBuckets.insert(spaceId)
                }
                rows[index].targetUpdatedDate = source.targetUpdatedDate
            }
            // §8.4.5: flag and count transferred only when written > 0.
            if decision.written > 0 {
                rows[index].pendingLocalEdit = true
                outcome.transferred += 1
            }
            if decision.contentSuperseded { outcome.transferSupersededByDelete += 1 }
        // The three 8b-2 operations match production primitives (ruling 5): address by
        // syncId including soft-deleted rows, write nothing for missing or unchanged values,
        // and never touch pendingLocalEdit.
        case .softDelete(let syncId, let mergePartnerSyncId):
            guard let index = rows.firstIndex(where: { $0.syncId == syncId }) else { return }
            // Write both columns together (RR8-4); do not rewrite deletedDate on already-soft-deleted rows.
            if rows[index].deletedDate == nil { rows[index].deletedDate = Date() }
            rows[index].mergePartnerSyncId = mergePartnerSyncId
            touchedBuckets.insert(rows[index].spaceId)
        case .setMergePartner(let syncId, let mergePartnerSyncId):
            guard let index = rows.firstIndex(where: { $0.syncId == syncId }),
                  rows[index].mergePartnerSyncId != mergePartnerSyncId else { return }
            // Do not record the bucket: this column affects neither routing nor order.
            rows[index].mergePartnerSyncId = mergePartnerSyncId
        case .setContentGroup(let syncId, let host, let pathPrefix, let ask,
                              let contentUpdatedDate):
            guard let index = rows.firstIndex(where: { $0.syncId == syncId }) else { return }
            let normalized = LocalStore.normalizedRule(host: host, pathPrefix: pathPrefix)
            // Write the three fields and their shared stamp; preserve sortOrder,
            // targetUpdatedDate, and deletedDate.
            rows[index].host = normalized.host
            rows[index].pathPrefix = normalized.pathPrefix
            rows[index].askBeforeRouting = ask
            rows[index].contentUpdatedDate = contentUpdatedDate
        }
    }

    /// Write 0..<n to live bucket rows ordered by (sortOrder, id).
    private func densify(_ bucket: String) {
        let live = rows.indices
            .filter { rows[$0].spaceId == bucket && rows[$0].deletedDate == nil }
            .sorted { (rows[$0].sortOrder, rows[$0].id) < (rows[$1].sortOrder, rows[$1].id) }
        for (position, index) in live.enumerated() {
            rows[index].sortOrder = position
        }
    }
}

// MARK: - Value-type fixtures

extension PhiLocalBookmark {
    /// Defaults for every argument let each case specify only the fields it tests.
    static func fixture(guid: String = "g1",
                        syncId: String? = nil,
                        spaceId: String = LocalStore.defaultSpaceId,
                        profileId: String = "Default",
                        parentGuid: String? = nil,
                        index: Int = 0,
                        isFolder: Bool = false,
                        title: String = "T",
                        url: URL = URL(string: "https://e.example")!,
                        secondaryUrl: URL? = nil,
                        secondaryTitle: String? = nil,
                        source: Int = 0,
                        createdDate: Date = Date(timeIntervalSince1970: 1_000),
                        contentUpdatedDate: Date? = nil,
                        locationUpdatedDate: Date? = nil) -> PhiLocalBookmark {
        PhiLocalBookmark(syncId: syncId, guid: guid, spaceId: spaceId, profileId: profileId,
                         parentGuid: parentGuid, index: index, isFolder: isFolder,
                         title: title, url: url, secondaryUrl: secondaryUrl,
                         secondaryTitle: secondaryTitle, source: source,
                         createdDate: createdDate, contentUpdatedDate: contentUpdatedDate,
                         locationUpdatedDate: locationUpdatedDate)
    }
}

extension PhiLocalPin {
    static func fixture(lineageId: String = "LX",
                        guid: String = "p1",
                        spaceId: String? = nil,
                        profileId: String? = "Default",
                        index: Int = 0,
                        title: String = "T",
                        url: URL = URL(string: "https://e.example")!,
                        splitPartnerLineageId: String? = nil,
                        source: Int = 0,
                        createdDate: Date = Date(timeIntervalSince1970: 1_000),
                        contentUpdatedDate: Date? = nil,
                        isDormant: Bool = false) -> PhiLocalPin {
        PhiLocalPin(lineageId: lineageId, guid: guid, spaceId: spaceId, profileId: profileId,
                    index: index, title: title, url: url,
                    splitPartnerLineageId: splitPartnerLineageId, source: source,
                    createdDate: createdDate, contentUpdatedDate: contentUpdatedDate,
                    isDormant: isDormant)
    }
}

extension PhiLocalURLRule {
    /// Default target space-a maps to su-1 through OwnerResolver.fixture. Default
    /// syncId=nil matches bookmark/pin fixtures; projection cases supply it explicitly.
    /// Both row stamps default to nil, so baseline-free projection falls back to createdDate.
    static func fixture(id: String = "i1", syncId: String? = nil,
                        spaceId: String = "space-a", host: String = "github.com",
                        pathPrefix: String? = nil, askBeforeRouting: Bool = false,
                        sortOrder: Int = 0,
                        createdDate: Date = Date(timeIntervalSince1970: 1_000),
                        contentUpdatedDate: Date? = nil, targetUpdatedDate: Date? = nil,
                        deletedDate: Date? = nil, pendingLocalEdit: Bool = false,
                        mergePartnerSyncId: String? = nil) -> PhiLocalURLRule {
        PhiLocalURLRule(id: id, syncId: syncId, spaceId: spaceId, host: host,
                        pathPrefix: pathPrefix, askBeforeRouting: askBeforeRouting,
                        sortOrder: sortOrder, createdDate: createdDate,
                        contentUpdatedDate: contentUpdatedDate,
                        targetUpdatedDate: targetUpdatedDate, deletedDate: deletedDate,
                        pendingLocalEdit: pendingLocalEdit,
                        mergePartnerSyncId: mergePartnerSyncId)
    }
}

extension URLRuleLandingValues {
    /// Nine application values; all three stamps default to one instant unless a case supplies them.
    static func fixture(syncId: String = "R1", spaceId: String = "S1", host: String = "github.com",
                        pathPrefix: String? = nil, askBeforeRouting: Bool = false, sortOrder: Int = 0,
                        createdDate: Date = Date(timeIntervalSince1970: 1_000),
                        contentUpdatedDate: Date = Date(timeIntervalSince1970: 1_000),
                        targetUpdatedDate: Date = Date(timeIntervalSince1970: 1_000)) -> URLRuleLandingValues {
        URLRuleLandingValues(syncId: syncId, spaceId: spaceId, host: host, pathPrefix: pathPrefix,
                             askBeforeRouting: askBeforeRouting, sortOrder: sortOrder,
                             createdDate: createdDate, contentUpdatedDate: contentUpdatedDate,
                             targetUpdatedDate: targetUpdatedDate)
    }
}

// MARK: - Payload builders returning generated proto types

/// PhiSettingValue is the schema's generic value-plus-LWW-stamp scalar, with one overload per v case.
func stamped(_ value: String, at ms: Int64) -> Phi_PhiSettingValue {
    var out = Phi_PhiSettingValue()
    out.updatedAtMs = ms
    out.stringValue = value
    return out
}

func stamped(_ value: Bool, at ms: Int64) -> Phi_PhiSettingValue {
    var out = Phi_PhiSettingValue()
    out.updatedAtMs = ms
    out.boolValue = value
    return out
}

func stamped(_ value: Int64, at ms: Int64) -> Phi_PhiSettingValue {
    var out = Phi_PhiSettingValue()
    out.updatedAtMs = ms
    out.intValue = value
    return out
}

/// Bookmark entity. space_uuid/parent_uuid share locationStamp (§4.3), rank has
/// its own stamp, and four content fields share contentStamp. secondary_url/title
/// have no parameters and emit explicit empty strings under the proto always-emit
/// rule. Omitting them changes has_... relative to the fixture's own snapshot,
/// producing false commits in every no-publication assertion.
func bookmarkPayload(uuid: String,
                     spaceUuid: String = "su-1",
                     parentUuid: String = "",
                     rank: String = "V",
                     isFolder: Bool = false,
                     title: String = "T",
                     url: String = "https://e.example",
                     locationStamp: Int64 = 100,
                     rankStamp: Int64 = 100,
                     contentStamp: Int64 = 100,
                     source: Int64 = 0,
                     createdAtMs: Int64 = 1_000) -> Phi_PhiBookmarkEntity {
    var entity = Phi_PhiBookmarkEntity()
    entity.bookmarkUuid = uuid
    entity.spaceUuid = stamped(spaceUuid, at: locationStamp)
    entity.parentUuid = stamped(parentUuid, at: locationStamp)
    entity.rank = stamped(rank, at: rankStamp)
    entity.isFolder = isFolder
    entity.title = stamped(title, at: contentStamp)
    entity.url = stamped(url, at: contentStamp)
    entity.secondaryURL = stamped("", at: contentStamp)
    entity.secondaryTitle = stamped("", at: contentStamp)
    entity.source = Int32(truncatingIfNeeded: source)
    entity.createdAtMs = createdAtMs
    return entity
}

/// Pin entity. ownerKey is the client tag's third segment, mapped to the owner
/// oneof: literal app leaves all cases absent (App scope is one of the three values);
/// su- prefix or LocalStore.defaultSpaceId selects Space; everything else selects
/// Profile. Fixtures use su-* Space UUIDs and pu-* Profile UUIDs.
func pinPayload(lineage: String,
                ownerKey: String = "pu-1",
                rank: String = "V",
                title: String = "T",
                url: String = "https://e.example",
                splitPartner: String = "",
                rankStamp: Int64 = 100,
                contentStamp: Int64 = 100,
                source: Int64 = 0,
                createdAtMs: Int64 = 1_000) -> Phi_PhiPinTabEntity {
    var entity = Phi_PhiPinTabEntity()
    entity.pinUuid = lineage
    if ownerKey == "app" {
        // Absent owner means App scope.
    } else if ownerKey.hasPrefix("su-") || ownerKey == LocalStore.defaultSpaceId {
        entity.spaceUuid = ownerKey
    } else {
        entity.profileUuid = ownerKey
    }
    entity.rank = stamped(rank, at: rankStamp)
    entity.title = stamped(title, at: contentStamp)
    entity.url = stamped(url, at: contentStamp)
    entity.splitPartnerUuid = stamped(splitPartner, at: contentStamp)
    entity.source = Int32(truncatingIfNeeded: source)
    entity.createdAtMs = createdAtMs
    return entity
}

/// URL-rule entity. Each merge unit has its own stamp (§8.2): three content
/// members share contentStamp, carried by host and emitted equally; target_space_uuid
/// uses targetStamp; rank uses rankStamp. path_prefix defaults to explicit empty
/// string, the wire match-any-path encoding for local nil. As with bookmark
/// secondary_url, omission changes has_... versus the fixture's snapshot and creates false commits.
func urlRulePayload(uuid: String,
                    targetSpaceUuid: String = "su-1",
                    host: String = "github.com",
                    pathPrefix: String = "",
                    ask: Bool = false,
                    rank: String = "V",
                    contentStamp: Int64 = 100,
                    targetStamp: Int64 = 100,
                    rankStamp: Int64 = 100,
                    source: Int64 = 0,
                    createdAtMs: Int64 = 1_000) -> Phi_PhiURLRuleEntity {
    var entity = Phi_PhiURLRuleEntity()
    entity.ruleUuid = uuid
    entity.host = stamped(host, at: contentStamp)
    entity.pathPrefix = stamped(pathPrefix, at: contentStamp)
    entity.ask = stamped(ask, at: contentStamp)
    entity.targetSpaceUuid = stamped(targetSpaceUuid, at: targetStamp)
    entity.rank = stamped(rank, at: rankStamp)
    entity.source = Int32(truncatingIfNeeded: source)
    entity.createdAtMs = createdAtMs
    return entity
}

/// Space entity used as context for bookmark space_uuid resolution. No profile_uuid
/// parameter means no emission; cases needing a binding set the mutable result.
/// D1's default Space carries neither theme_id nor profile_uuid.
func spacePayload(uuid: String, name: String = "S", stamp: Int64 = 100) -> Phi_PhiSpaceEntity {
    var entity = Phi_PhiSpaceEntity()
    entity.spaceUuid = uuid
    entity.name = stamped(name, at: stamp)
    entity.iconName = stamped("emoji:1F4BC", at: stamp)
    entity.colorHex = stamped("#3A6FF8", at: stamp)
    entity.rank = stamped("V", at: stamp)
    if uuid != LocalStore.defaultSpaceId {
        entity.themeID = stamped("", at: stamp)
    }
    entity.overlayOpacityLight = stamped(Int64(-1), at: stamp)
    entity.overlayOpacityDark = stamped(Int64(-1), at: stamp)
    entity.createdAtMs = 1_000
    return entity
}

func envelope(_ payload: Phi_PhiBookmarkEntity) -> Phi_PhiEntity {
    var out = Phi_PhiEntity()
    out.bookmark = payload
    return out
}

func envelope(_ payload: Phi_PhiPinTabEntity) -> Phi_PhiEntity {
    var out = Phi_PhiEntity()
    out.pinTab = payload
    return out
}

func envelope(_ payload: Phi_PhiSpaceEntity) -> Phi_PhiEntity {
    var out = Phi_PhiEntity()
    out.space = payload
    return out
}

/// Baseline bytes from envelope(payload).serializedData(), stored as reconciled/server on cursors.
func baselineBytes(_ payload: Phi_PhiBookmarkEntity) -> Data {
    (try? envelope(payload).serializedData()) ?? Data()
}

func baselineBytes(_ payload: Phi_PhiPinTabEntity) -> Data {
    (try? envelope(payload).serializedData()) ?? Data()
}

func envelope(_ payload: Phi_PhiURLRuleEntity) -> Phi_PhiEntity {
    var out = Phi_PhiEntity()
    out.urlRule = payload
    return out
}

func baselineBytes(_ payload: Phi_PhiURLRuleEntity) -> Data {
    (try? envelope(payload).serializedData()) ?? Data()
}

// MARK: - Protocol fixtures

/// Fake pages contain PhiRemoteEntity from PhiSyncProtocolClient.swift, not generated
/// wire SyncPb_SyncEntity messages. tag is a client tag such as phi-bookmark:<uuid>;
/// compute its hash here.
func remoteEntity(_ envelope: Phi_PhiEntity,
                  tag: String,
                  version: Int64,
                  entityId: String = "srv-1",
                  key: SymmetricKey) -> PhiRemoteEntity {
    PhiRemoteEntity(entityId: entityId,
                    clientTagHash: PhiSyncEntity.clientTagHash(for: tag),
                    version: version,
                    ciphertext: (try? PhiEntityCodec.encrypt(envelope, key: key)) ?? Data(),
                    deleted: false)
}

func remoteTombstone(tag: String, version: Int64, entityId: String = "srv-1") -> PhiRemoteEntity {
    PhiRemoteEntity(entityId: entityId,
                    clientTagHash: PhiSyncEntity.clientTagHash(for: tag),
                    version: version,
                    ciphertext: Data(),
                    deleted: true)
}

/// Random, undecryptable ciphertext for §5.5 isolation tests.
func remoteUnreadable(tag: String, version: Int64) -> PhiRemoteEntity {
    PhiRemoteEntity(entityId: "srv-1",
                    clientTagHash: PhiSyncEntity.clientTagHash(for: tag),
                    version: version,
                    ciphertext: Data((0..<32).map { _ in UInt8.random(in: UInt8.min...UInt8.max) }),
                    deleted: false)
}

/// Payload with no kind oneof for the dispatcher fallback.
func remoteUnknownKind(tag: String, version: Int64, key: SymmetricKey) -> PhiRemoteEntity {
    remoteEntity(Phi_PhiEntity(), tag: tag, version: version, key: key)
}

func remoteSettingsEntity(key settingKey: String, value: String,
                          version: Int64, key: SymmetricKey) -> PhiRemoteEntity {
    var setting = Phi_PhiSettingEntity()
    setting.values[settingKey] = stamped(value, at: 100)
    var wrapper = Phi_PhiEntity()
    wrapper.setting = setting
    return remoteEntity(wrapper, tag: PhiSyncEntity.clientTag, version: version, key: key)
}

/// Convenience builder for FakePhiSyncClient.Page.
func page(_ entities: [PhiRemoteEntity],
          marker: String = "m1",
          changesRemaining: Bool = false) -> PhiSyncEngineTests.FakePhiSyncClient.Page {
    PhiSyncEngineTests.FakePhiSyncClient.Page(entities: entities,
                                              newMarker: Data(marker.utf8),
                                              changesRemaining: changesRemaining)
}

// MARK: - Commit filtering

/// Bookmark-tag commits only. Settings and Space entities share the commits list
/// but are outside these assertions.
func bookmarkCommits(_ client: PhiSyncEngineTests.FakePhiSyncClient)
    -> [PhiSyncEngineTests.FakePhiSyncClient.CommitCall] {
    client.commits.filter { $0.name == PhiSyncEntity.bookmarkEntityName }
}

func pinCommits(_ client: PhiSyncEngineTests.FakePhiSyncClient)
    -> [PhiSyncEngineTests.FakePhiSyncClient.CommitCall] {
    client.commits.filter { $0.name == PhiSyncEntity.pinEntityName }
}

/// Decrypt bookmark_uuid for ordering assertions; tombstones with nil ciphertext
/// and undecryptable ciphertext return nil.
func committedBookmarkUuid(_ call: PhiSyncEngineTests.FakePhiSyncClient.CommitCall,
                           key: SymmetricKey) -> String? {
    guard let ciphertext = call.ciphertext,
          let entity = try? PhiEntityCodec.decrypt(ciphertext, key: key),
          case .bookmark(let payload)? = entity.kind else { return nil }
    return payload.bookmarkUuid
}

/// Likewise for pin_uuid lineage, without owner. One lineage under N owners is
/// N entities; use clientTagHash to distinguish them.
func committedPinIdentity(_ call: PhiSyncEngineTests.FakePhiSyncClient.CommitCall,
                          key: SymmetricKey) -> String? {
    guard let ciphertext = call.ciphertext,
          let entity = try? PhiEntityCodec.decrypt(ciphertext, key: key),
          case .pinTab(let payload)? = entity.kind else { return nil }
    return payload.pinUuid
}

// MARK: - Cursor fixtures and in-memory stores

/// Live cursor with no deletedAtMs or pending flags. Expose only fields selected
/// by tests; other values use PhiOwnedItemCursor defaults so each case states what matters.
func ownedCursor(reconciled: Data? = nil, server: Data? = nil,
                 entityId: String = "", version: Int64 = 0,
                 ownerUuid: String? = nil) -> PhiOwnedItemCursor {
    var cursor = PhiOwnedItemCursor()
    cursor.entityId = entityId
    cursor.version = version
    cursor.reconciled = reconciled
    cursor.server = server
    cursor.ownerUuid = ownerUuid
    return cursor
}

/// Pending-tombstone cursor: pendingDelete is set and deleteDecidedAtMs records
/// the diff's decision time, compared with inbound location stamps by §5.6 L1.
/// deletedAtMs remains nil until the server accepts and finalizes deletion.
func pendingDeleteCursor(decidedAtMs: Int64, entityId: String = "srv-1",
                         version: Int64 = 1, rejectRounds: Int = 0,
                         reconciled: Data? = nil) -> PhiOwnedItemCursor {
    var cursor = ownedCursor(reconciled: reconciled, entityId: entityId, version: version)
    cursor.pendingDelete = true
    cursor.deleteDecidedAtMs = decidedAtMs
    cursor.deleteRejectRounds = rejectRounds
    return cursor
}

/// Purged Space cursor for §9.3 retention cascades, matching purgeExpired output:
/// retain entityId/version, hidden/deletedAtMs, and add purgedAtMs. Space invariant:
/// hidden implies a nonnil deletedAtMs.
func purgedSpaceCursor(purgedAtMs: Int64 = 1) -> PhiSpaceCursor {
    var cursor = PhiSpaceCursor()
    cursor.entityId = "srv-space"
    cursor.version = 1
    cursor.hidden = true
    cursor.deletedAtMs = purgedAtMs
    cursor.purgedAtMs = purgedAtMs
    return cursor
}

/// In-memory PhiOwnedItemStateStore. The protocol requires AnyObject, and the
/// fake relies on it: engine load must observe test mutations of table.
final class MemoryOwnedItemStore: PhiOwnedItemStateStore {
    var table: PhiOwnedItemTable
    /// Every load reports file loss.
    var forcedLoss = false
    /// Report loss only on the Nth load, counting from 1. Cases where apply reads an
    /// old table but publication discovers loss need the intervening half-round to finish normally.
    var loseOnLoadNumber: Int?
    private(set) var deleted = false
    /// Record hadRecords for every load in call order. Loss reporting depends on it,
    /// so these assertions identify which per-kind flag the engine supplied.
    private(set) var hadRecordsSeen: [Bool] = []
    /// When true, every save returns false without changing table, modeling R-M3-4a-83.
    /// Tests set it false to permit writes again.
    var failNextSave = false
    /// Fail only save number N, counting saveCalls from 1, without changing table.
    /// B-2 cases need precise failures at final-page application or publication.
    var failSaveOnCallNumber: Int?
    private(set) var saveCalls = 0

    init(table: PhiOwnedItemTable = PhiOwnedItemTable()) {
        self.table = table
    }

    /// Match all four production loss conditions. forcedLoss/loseOnLoadNumber model
    /// missing, undecodable, or old-version files; an empty cursor table must independently
    /// trigger loss, as FileOwnedItemStateStore does (CASE 3.6). Otherwise fake Task 6/9
    /// rounds would pass normally where production reports loss and replays the full type.
    /// reportedLoss always takes hadRecords: forcedLoss means missing file, not unconditional
    /// loss. With hadRecords=false, the file was never expected. Leave table unchanged
    /// so tests can still inspect subsequent engine writes.
    func load(hadRecords: Bool) -> (table: PhiOwnedItemTable, reportedLoss: Bool) {
        hadRecordsSeen.append(hadRecords)
        let loses = forcedLoss || loseOnLoadNumber == hadRecordsSeen.count || table.cursors.isEmpty
        guard loses else { return (table, false) }
        return (PhiOwnedItemTable(), hadRecords)
    }

    @discardableResult
    func save(_ table: PhiOwnedItemTable) -> Bool {
        saveCalls += 1
        guard !failNextSave, failSaveOnCallNumber != saveCalls else { return false }
        self.table = table
        return true
    }

    func deleteFile() {
        deleted = true
        table = PhiOwnedItemTable()
    }
}

/// In-memory PhiSyncMarkerStore (M3-4a Task 3), matching MemoryOwnedItemStore.
/// Keep it top-level so PhiSyncMarkerBoundaryTests and SelfRevokeTests share it.
/// saves records every attempted table, including failures; saves.count is both
/// call count and failSaveOnCallNumber's index. Assert saves.isEmpty for no writes.
final class MemoryMarkerStore: PhiSyncMarkerStore {
    var file: PhiSyncMarkerFile
    /// Every save fails, modeling full disk or an unwritable directory for Task 2b's third flag-setting point.
    var failSave = false
    /// Fail only the Nth save, counting from 1, for precise page-boundary failures.
    var failSaveOnCallNumber: Int?
    private(set) var saves: [PhiSyncMarkerFile] = []
    private(set) var loadCount = 0
    private(set) var deleted = false

    init(file: PhiSyncMarkerFile = PhiSyncMarkerFile()) {
        self.file = file
    }

    func load() -> PhiSyncMarkerFile {
        loadCount += 1
        return file
    }

    /// Failure preserves file (R-M3-4a-83): memory and simulated disk retain the old table.
    @discardableResult
    func save(_ file: PhiSyncMarkerFile) -> Bool {
        saves.append(file)
        if failSave || failSaveOnCallNumber == saves.count { return false }
        self.file = file
        return true
    }

    /// Delete rather than save an empty table: set deleted and reset file so the next
    /// load matches the real store's missing-file result.
    func deleteFile() {
        deleted = true
        file = PhiSyncMarkerFile()
    }
}

// MARK: - CASE 0.1 – 0.5

/// Shared support for all M3-3 owned-item bookmark/pin tests and Task 0's five cases.
/// Follow PhiSpaceLocalAccessTests: top-level fakes plus XCTestCase in one file.
/// Both protocols and their fakes are MainActor, so isolate the entire test class too.
@MainActor
final class OwnedItemsTestSupportTests: XCTestCase {

    /// Number the three phases independently of BookmarkApplyBatch's sorting code;
    /// using the implementation's own comparator would verify nothing.
    private func phase(_ op: BookmarkApplyOp) -> Int {
        switch op {
        case .claim, .create, .move: return 1
        case .update: return 2
        case .delete: return 3
        }
    }

    private func createGuids(_ ops: [BookmarkApplyOp]) -> [String] {
        ops.compactMap { if case .create(let row) = $0 { return row.guid } else { return nil } }
    }

    private func deleteGuids(_ ops: [BookmarkApplyOp]) -> [String] {
        ops.compactMap { if case .delete(let guid) = $0 { return guid } else { return nil } }
    }

    /// CASE 0.1: sort batches into three phases. Interleaving phases or reversing
    /// parent/child order can update deleted rows or create children before their parents exist.
    func testBookmarkBatchSortsOpsIntoThreePhasesWithParentsBeforeChildren() {
        let unordered: [BookmarkApplyOp] = [
            .delete(guid: "child"),
            .create(.fixture(guid: "child", parentGuid: "parent")),
            .update(guid: "other", fields: BookmarkFieldPatch(title: "T")),
            .delete(guid: "parent"),
            .create(.fixture(guid: "parent", isFolder: true)),
        ]

        let ops = BookmarkApplyBatch(unordered: unordered, parentOf: ["child": "parent"]).ops

        let phases = ops.map(phase)
        XCTAssertEqual(phases, phases.sorted(), "Phase numbers must be nondecreasing")
        XCTAssertEqual(createGuids(ops), ["parent", "child"], "Parents precede children within the create phase")
        XCTAssertEqual(deleteGuids(ops), ["child", "parent"], "Children precede parents within the delete phase")
    }

    /// CASE 0.2: never delete an ancestor before operating on its descendants.
    /// Deleting the parent first cascades away a child; updating it then throws
    /// rowNotFound after Task 2a, rolling back the whole batch forever.
    func testAnAncestorDeleteNeverPrecedesAnOperationOnItsDescendant() {
        let unordered: [BookmarkApplyOp] = [
            .delete(guid: "parent"),
            .update(guid: "child", fields: BookmarkFieldPatch(title: "T")),
        ]

        let ops = BookmarkApplyBatch(unordered: unordered, parentOf: ["child": "parent"]).ops

        let updateIndex = ops.firstIndex { if case .update = $0 { return true } else { return false } }
        let deleteIndex = ops.firstIndex { if case .delete = $0 { return true } else { return false } }
        XCTAssertNotNil(updateIndex)
        XCTAssertNotNil(deleteIndex)
        guard let updateIndex, let deleteIndex else { return }
        XCTAssertLessThan(updateIndex, deleteIndex)
    }

    /// CASE 0.3: record fake calls with an enum. String arrays would diverge from
    /// FakePhiSpaceAccess.Call and break reuse of existing assertion patterns.
    func testFakeBookmarkAccessRecordsCallsAsEnumCases() async throws {
        let fake = FakeBookmarkAccess(rows: [.fixture(guid: "g1")])

        _ = try fake.allBookmarks()
        try await fake.apply(BookmarkApplyBatch(unordered: [.delete(guid: "g1")]))

        let calls = fake.calls
        XCTAssertEqual(calls, [.allBookmarks, .apply(opCount: 1)])
    }

    /// CASE 0.4: siblings does not fetch again. Repeated fetching rescans large trees
    /// several times per round and may observe user changes between reads.
    func testSiblingsIsAnInMemoryGroupingRatherThanASecondFetch() throws {
        let fake = FakeBookmarkAccess(rows: [
            .fixture(guid: "a", parentGuid: "p", index: 0),
            .fixture(guid: "b", parentGuid: "p", index: 1),
        ])

        _ = try fake.allBookmarks()
        let siblings = fake.siblings(ofParent: "p", inSpaceId: LocalStore.defaultSpaceId)

        let siblingCount = siblings.count
        let fetchCount = fake.calls.filter { $0 == .allBookmarks }.count
        XCTAssertEqual(siblingCount, 2)
        XCTAssertEqual(fetchCount, 1)
    }

    /// CASE 0.5: App-scope pins have both owner fields nil. A nonoptional profileId
    /// cannot represent App scope or test that row of §7.2's owner-inference table.
    func testAnAppScopedPinFixtureCarriesNeitherOwnerId() {
        let pin = PhiLocalPin.fixture(spaceId: nil, profileId: nil)

        let spaceId = pin.spaceId
        let profileId = pin.profileId
        XCTAssertNil(spaceId)
        XCTAssertNil(profileId)
    }
}

// MARK: - Owner-resolver fixtures

extension OwnerResolver {
    /// Shared resolver: space-a → su-1, space-b → su-2, Default → pu-1. Derive reverse
    /// mappings from the forward table to keep both directions consistent; separate
    /// handwritten tables drift and falsely trigger unresolved-owner paths.
    ///
    /// ineligible UUIDs make isEligibleSpace false, modeling hidden/purged Spaces.
    /// Unknown UUIDs return true: eligibility applies only to Space ownership, while
    /// Profile/App pins use the other members. Rejecting them here would stop whole pin kinds from publishing.
    static func fixture(spaceUuids: [String: String] = ["space-a": "su-1", "space-b": "su-2"],
                        profileUuids: [String: String] = ["Default": "pu-1"],
                        ineligible: Set<String> = [],
                        spaceProfiles: [String: String] = [:]) -> OwnerResolver {
        var spacesByUuid: [String: String] = [:]
        for (localId, uuid) in spaceUuids { spacesByUuid[uuid] = localId }
        var profilesByUuid: [String: String] = [:]
        for (localId, uuid) in profileUuids { profilesByUuid[uuid] = localId }
        return OwnerResolver(syncUuid: { spaceUuids[$0] },
                             localSpaceId: { spacesByUuid[$0] },
                             isEligibleSpace: { !ineligible.contains($0) },
                             globalUuid: { profileUuids[$0] },
                             localProfileId: { profilesByUuid[$0] },
                             localProfileIdForSpace: { spaceProfiles[$0] })
    }
}

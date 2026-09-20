// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

// URL-rule adaptation: encoding, three-unit LWW, owner resolution, and stamping (§5.1).
// Rules add a third ownership model (§5.2 / D13): the owner can change without changing identity.
// Under D15 / R-M3-4a-40, the content group (host, path_prefix, ask) shares the host stamp; send
// all three stamps equal and read only host on receipt. Target and rank each have their own stamp;
// target is this kind's location.
// Separating target from content gives `locationStamp(of:)` a direct source for A9's first
// condition and preserves concurrent host and target edits (§8.2 rule 2). D30
// signatures/rest/transfer/deferred deletion belong to 8b-1–8b-3; Task 8 owns local access/batches,
// and Task 6 owns planning/registration.

enum URLRuleKind: OwnedItemKind {
    typealias Entity = Phi_PhiURLRuleEntity
    typealias Local = PhiLocalURLRule

    static var tagPrefix: String { PhiSyncEntity.urlRuleTagPrefix }
    static var entityName: String { PhiSyncEntity.urlRuleEntityName }

    // MARK: - Identity and envelope

    static func identity(of entity: Phi_PhiURLRuleEntity) -> String { entity.ruleUuid }

    /// Return `local.syncId`, which is non-nil by construction at insertion (R-M3-4a-23). The
    /// module's first-pass missing-identity skip is unreachable for rules, so they need neither
    /// snapshot minting nor `claimIdentities`.
    static func identity(of local: PhiLocalURLRule, resolve: OwnerResolver,
                         scope: PinnedTabScope?) -> String? {
        local.syncId
    }

    static func envelope(_ entity: Phi_PhiURLRuleEntity) -> Phi_PhiEntity {
        var out = Phi_PhiEntity()
        out.urlRule = entity
        return out
    }

    static func entity(from envelope: Phi_PhiEntity) -> Phi_PhiURLRuleEntity? {
        guard case .urlRule(let payload)? = envelope.kind else { return nil }
        return payload
    }

    /// Rules have no dependency edges, so topological sorting is trivial.
    static func localEdge(of local: PhiLocalURLRule) -> (id: String, parentId: String?) {
        (id: local.id, parentId: nil)
    }

    // MARK: - Ownership (§5.3)

    /// Evaluate §5.3's three rules in order, first match wins (R-M3-4a-7 / 8):
    /// 1. The bare Incognito target maps to the eligible reserved constant.
    /// 2. Other incognito-prefixed ids (stale runtime Spaces) and agent Spaces are ineligible and
    /// return nil.
    /// 3. Otherwise resolve through mappings, returning nil on failure.
    /// Leave current-Space presence and hidden/purged cursor checks to the module. The engine's
    /// `isEligibleSpace` already combines them, and the module counts resolved but ineligible rows
    /// as `skippedIneligibleOwner`. Returning nil here would keep that counter permanently zero for
    /// rules and erase the distinction between both exclusion paths.
    static func eligibilityOwner(of local: PhiLocalURLRule, resolve: OwnerResolver,
                                 scope: PinnedTabScope?) -> String? {
        if local.spaceId == SpaceManager.incognitoRuleTargetId {
            return SyncableSpaces.incognitoSpaceUuid
        }
        if !SpaceManager.isRoutableRuleTarget(local.spaceId) { return nil }
        return resolve.syncUuid(local.spaceId)
    }

    /// Always return `[target_space_uuid]`, including reserved constants (R-M3-4a-7 revision). This
    /// also supplies the rank group key via NUL-joined owners, so incognito rules form the
    /// `incognito-space` group like any target. Return an array containing the empty string for an
    /// empty target: classification then parks it as unresolved. An empty array would allow landing
    /// with an empty target, violating D16's no-rewrite rule.
    static func ownerUuids(of entity: Phi_PhiURLRuleEntity) -> [String] {
        [entity.targetSpaceUuid.stringValue]
    }

    /// Read the target field directly (R-M3-4a-26), not the first owner reference. Values currently
    /// coincide, but owner references describe what must resolve before landing; a future kind may
    /// omit a reference from that requirement. A move needs the entity's actual destination.
    static func targetOwnerUuid(of entity: Phi_PhiURLRuleEntity) -> String? {
        entity.targetSpaceUuid.stringValue
    }

    // MARK: - Tombstone yielding (§8.4.4, 8b-3)

    /// §6.1: rules yield when an inbound tombstone meets unpublished local user intent. Transfer
    /// that edit to the merged survivor (i), or republish this identity (ii), instead of
    /// hard-deleting it. Bookmarks/pins retain the protocol's false default this milestone (§14.1).
    static var tombstoneYieldsToLocalEdits: Bool { true }

    /// §8.4.4 transfer projection, shared by both inputs: X's local projection at (α), and this
    /// round's merged entity at (β).
    /// Resolve the account target to local `targetSpaceId` (ruling 3), since landing writes the
    /// local column and storage knows no account mappings. Resolve the reserved incognito constant
    /// separately because `localSpaceId` deliberately does not map it (R-7). An empty host returns
    /// nil, failing closed so the caller takes branch (ii).
    static func transferSource(of entity: Phi_PhiURLRuleEntity,
                               resolve: OwnerResolver) -> RuleProjection? {
        let host = entity.host.stringValue
        guard !host.isEmpty else { return nil }
        let wirePath = entity.pathPrefix.stringValue
        let target = entity.targetSpaceUuid.stringValue
        return RuleProjection(host: host,
                              // Wire empty string maps to local nil (§8.1).
                              pathPrefix: wirePath.isEmpty ? nil : wirePath,
                              askBeforeRouting: entity.ask.boolValue,
                              contentUpdatedDate: stampDate(entity.host.updatedAtMs),
                              targetOwnerUuid: target,
                              targetSpaceId: localSpaceId(of: target, resolve: resolve),
                              targetUpdatedDate: stampDate(entity.targetSpaceUuid.updatedAtMs))
    }

    /// Account target -> local `spaceId`, using the same rule as the local helper in
    /// `landURLRules`.
    private static func localSpaceId(of target: String, resolve: OwnerResolver) -> String? {
        guard !target.isEmpty else { return nil }
        if target == SyncableSpaces.incognitoSpaceUuid { return SpaceManager.incognitoRuleTargetId }
        return resolve.localSpaceId(target)
    }

    // MARK: - Outbound projection and stamps (§8.2)

    /// Project a local row to a wire entity without stamps or rank. Rules have no parent, so ignore
    /// `parentIdentity`. An unresolved target returns nil and skips the entire row this round
    /// (§5.3).
    static func project(_ local: PhiLocalURLRule, resolve: OwnerResolver,
                        scope: PinnedTabScope?, parentIdentity: String?) -> Phi_PhiURLRuleEntity? {
        guard let target = eligibilityOwner(of: local, resolve: resolve, scope: scope) else {
            return nil
        }
        var entity = Phi_PhiURLRuleEntity()
        entity.ruleUuid = local.syncId ?? ""
        entity.host = string(local.host)
        // Local nil maps to wire empty string, explicitly clearing the path to match any path
        // (§8.1).
        entity.pathPrefix = string(local.pathPrefix ?? "")
        entity.ask = bool(local.askBeforeRouting)
        entity.targetSpaceUuid = string(target)
        entity.rank = string("")
        entity.createdAtMs = milliseconds(local.createdDate)
        // There is no local source column (§3.3). Publish zero here; `stamp` restores a nonzero
        // baseline source.
        entity.source = 0
        return entity
    }

    static func rank(of entity: Phi_PhiURLRuleEntity) -> String { entity.rank.stringValue }

    /// Bytes of the content group (host/path_prefix/ask) with stamps cleared. Exclude target, now a
    /// separate move unit under R-40, and rank. Also exclude non-LWW creation/source fields, which
    /// `stamp` folds back in.
    static func contentSignature(of entity: Phi_PhiURLRuleEntity) -> Data {
        var out = Data()
        for value in [entity.host, entity.pathPrefix, entity.ask] {
            out.append(SyncableSettings.signature(of: value))
            out.append(0)
        }
        return out
    }

    /// Read only the target field's own stamp (R-M3-4a-25), as bookmark location stamping does.
    /// `stamp` writes it; this accessor reads it. Using content time for A9's first condition would
    /// let a newer remote content edit cancel a local deletion (CASE U-23).
    static func locationStamp(of entity: Phi_PhiURLRuleEntity) -> Int64 {
        entity.targetSpaceUuid.updatedAtMs
    }

    /// §8.2 stamping (D33): engine writes mint no edit stamps; only derived rank uses `now`.
    /// Content: compare all three members as one signature. On change, use row `contentUpdatedDate
    /// ?? createdDate`, the actual user-edit time (R-11); otherwise retain the baseline host stamp.
    /// Always write equal stamps to all three members. Snapshot time would let an older delayed
    /// local edit defeat a newer real peer edit. The controller applies §8.2 / D33 over the
    /// bookmark precedent for this kind.
    /// Target: on change, use `targetUpdatedDate ?? createdDate` and stamp rank with `now`, because
    /// changing buckets creates a new position even if the rank string coincidentally stays equal
    /// (§8.2 rule 4). Otherwise preserve the target stamp and compare rank independently.
    /// Without a baseline (R-12), use each content/target row stamp or creation time, and rank
    /// stamp zero. Using `now` would let an untouched old local rule defeat a recent peer retarget;
    /// using target stamp zero would make A9 impossible for unpublished rules. This is the main
    /// path for first publication and loss replay.
    /// With a baseline, first fold in creation time and source (R-exec-16 / R-19), following
    /// bookmarks. Values that cannot be represented locally must not cause perpetual byte
    /// differences and alternating commits.
    static func stamp(_ projected: Phi_PhiURLRuleEntity, baseline: Phi_PhiURLRuleEntity?,
                      local: PhiLocalURLRule, rank: String, now: Int64) -> Phi_PhiURLRuleEntity {
        var out = projected
        out.rank = string(rank)

        guard let baseline else {
            setContentStamp(&out, milliseconds(local.contentUpdatedDate ?? local.createdDate))
            out.targetSpaceUuid.updatedAtMs = milliseconds(local.targetUpdatedDate ?? local.createdDate)
            out.rank.updatedAtMs = 0
            return out
        }

        out.createdAtMs = mergedCreatedAtMs(out.createdAtMs, baseline.createdAtMs)
        // Source is a write-once provenance tag. Preserve a nonzero baseline value instead of
        // replacing it with local zero.
        if baseline.source != 0 { out.source = baseline.source }

        let contentChanged = contentSignature(of: out) != contentSignature(of: baseline)
        setContentStamp(&out, contentChanged
                            ? milliseconds(local.contentUpdatedDate ?? local.createdDate)
                            : baseline.host.updatedAtMs)

        let targetChanged = SyncableSettings.signature(of: out.targetSpaceUuid)
            != SyncableSettings.signature(of: baseline.targetSpaceUuid)
        if targetChanged {
            out.targetSpaceUuid.updatedAtMs = milliseconds(local.targetUpdatedDate ?? local.createdDate)
            out.rank.updatedAtMs = now
        } else {
            out.targetSpaceUuid.updatedAtMs = baseline.targetSpaceUuid.updatedAtMs
            out.rank.updatedAtMs = restamped(out.rank, baseline.rank, now)
        }
        return out
    }

    // MARK: - Merge (§8.2)

    /// §8.2 merges symmetrically: content = whole-group LWW; target = LWW; rank = rank LWW when
    /// targets match, otherwise the target winner's rank.
    /// Host and path are halves of one match key. Per-field merging could activate a rule neither
    /// user wrote. Compare only the fixed host carrier stamp, never the maximum of all three;
    /// differing stamp interpretations would make peers each claim victory and republish forever.
    /// Rank belongs to its target bucket. Selecting the target winner's rank must work
    /// symmetrically, regardless of which side wins. Start from `remote` to preserve unknown fields
    /// written by newer clients; a fresh message would erase them on every round.
    static func merge(local: Phi_PhiURLRuleEntity,
                      remote: Phi_PhiURLRuleEntity) -> Phi_PhiURLRuleEntity {
        var merged = remote
        merged.ruleUuid = local.ruleUuid.isEmpty ? remote.ruleUuid : local.ruleUuid

        let localBallot = contentBallot(local)
        let remoteBallot = contentBallot(remote)
        let contentWinner = SyncableSettings.lwwWinner(localBallot, remoteBallot) == localBallot
            ? local : remote
        merged.host = contentWinner.host
        merged.pathPrefix = contentWinner.pathPrefix
        merged.ask = contentWinner.ask
        // §8.2 rule 1: send all three content stamps equal to the winning carrier stamp.
        setContentStamp(&merged, contentWinner.host.updatedAtMs)

        let targetWinner = SyncableSettings.lwwWinner(local.targetSpaceUuid, remote.targetSpaceUuid)
        merged.targetSpaceUuid = targetWinner
        if local.targetSpaceUuid.stringValue == remote.targetSpaceUuid.stringValue {
            merged.rank = SyncableSettings.lwwWinner(local.rank, remote.rank)
        } else {
            merged.rank = targetWinner == local.targetSpaceUuid ? local.rank : remote.rank
        }

        // Not LWW: prefer a nonzero source; if both differ and are nonzero, choose the smaller.
        merged.source = mergedSource(local.source, remote.source)
        // Not LWW: preserve the earliest creation time.
        merged.createdAtMs = mergedCreatedAtMs(local.createdAtMs, remote.createdAtMs)
        return merged
    }

    // MARK: - Refusal (§5.4)

    /// Evaluate §5.4 structural predicates in table order; nil accepts. Rules have no shape
    /// invariant like `is_folder`, so the baseline is unused.
    /// Rank validation protects `rankBetween`, whose release precondition traps on invalid peer
    /// input (CASE U-9). Host colon validation must accept bracketed IPv6: GURL returns `[::1]`,
    /// and editor port stripping preserves it. Otherwise a valid locally matching rule would be
    /// refused on every peer every round, since this predicate has no refusal timestamp.
    /// Do not reject noncanonical paths or unresolved targets here. Planning normalizes paths
    /// through `normalizeArrivals`; owner classification parks unresolved targets.
    static func refuses(_ entity: Phi_PhiURLRuleEntity,
                        baseline: Phi_PhiURLRuleEntity?) -> OwnedItemRefusal? {
        guard isAccountUuid(entity.ruleUuid) else { return .invalidUuid }
        guard SyncableSpaces.isLegalRank(entity.rank.stringValue) else { return .illegalRank }
        let host = entity.host.stringValue
        if host.isEmpty { return .emptyHost }
        if host == "*" || host == "*." { return .degenerateHost }
        if host.contains("/") { return .malformedHost }
        if host.contains(":"), !(host.hasPrefix("[") && host.hasSuffix("]")) {
            return .malformedHost
        }
        return nil
    }

    // MARK: - Landing projection (§8.3)

    /// Convert wire rank to dense local `sortOrder` once per bucket, sorting ascending by `(rank ??
    /// "", syncId ?? id)` as in bookmark rank projection. Return local id -> order.
    /// Include parked, pending-delete, and unpublished siblings without sync-eligibility filtering.
    /// Missing ranks sort first, matching rank-assignment complements; identity fallback provides a
    /// stable tie-break. Exclude soft-deleted rows here, the single R-51 implementation point: they
    /// neither route nor display, and including them misaligns order across devices. Order is
    /// routing specificity's third component, before the final tie-break key. Rehome callers
    /// project both source and target buckets (R-3).
    static func rankToSortOrder(siblings: [PhiLocalURLRule],
                                ranks: [String: String]) -> [String: Int] {
        let ordered = siblings.filter { $0.deletedDate == nil }.sorted { left, right in
            let leftRank = left.syncId.flatMap { ranks[$0] } ?? ""
            let rightRank = right.syncId.flatMap { ranks[$0] } ?? ""
            if leftRank != rightRank { return leftRank < rightRank }
            return (left.syncId ?? left.id) < (right.syncId ?? right.id)
        }
        var out: [String: Int] = [:]
        for (index, row) in ordered.enumerated() { out[row.id] = index }
        return out
    }

    // MARK: - Inbound normalization (§8.1 / R-M3-4a-29)

    /// Pure planning step 0: normalize each decoded arrival, replacing changed values without
    /// changing any stamps. Return changed identities so the caller records normalization and adds
    /// them to `mustRepublish`. Inject normalization rather than accessing storage from this pure
    /// module. Convert wire empty path and local nil at this boundary.
    /// Do not silently normalize before refusal/planning: refusal cannot return a rewritten entity,
    /// and the planner detects republish by comparing payload bytes. An untracked external rewrite
    /// would hide that difference. Preserve remote stamps (R-2 / D33); fixed-point normalization
    /// guarantees termination because the peer also projects normalized values. Minting `now` would
    /// fabricate freshness capable of defeating a real user edit.
    static func normalizeArrivals(
        _ arrivals: [OwnedItemArrival<Phi_PhiURLRuleEntity>],
        normalize: (String, String?) -> (host: String, pathPrefix: String?)
    ) -> (arrivals: [OwnedItemArrival<Phi_PhiURLRuleEntity>], normalized: Set<String>) {
        var out = arrivals
        var normalized: Set<String> = []
        for (offset, item) in arrivals.enumerated() {
            let wireHost = item.entity.host.stringValue
            let wirePath = item.entity.pathPrefix.stringValue
            let result = normalize(wireHost, wirePath.isEmpty ? nil : wirePath)
            let path = result.pathPrefix ?? ""
            guard result.host != wireHost || path != wirePath else { continue }
            // Replace values only: the string-value setter changes the oneof while retaining
            // `updatedAtMs`.
            var entity = item.entity
            entity.host.stringValue = result.host
            entity.pathPrefix.stringValue = path
            out[offset].entity = entity
            let identity = identity(of: entity)
            if !identity.isEmpty { normalized.insert(identity) }
        }
        return (out, normalized)
    }

    // MARK: - Private helpers

    /// Represent the whole content group as one ballot for `SyncableSettings.lwwWinner`. Use host's
    /// carrier stamp and all three values; serialized-byte lexical tie-breaking stays symmetric.
    private static func contentBallot(_ entity: Phi_PhiURLRuleEntity) -> Phi_PhiSettingValue {
        var ballot = string(entity.host.stringValue + "\u{0}" + entity.pathPrefix.stringValue
                            + "\u{0}" + (entity.ask.boolValue ? "1" : "0"))
        ballot.updatedAtMs = entity.host.updatedAtMs
        return ballot
    }

    /// §8.2 rule 1: assign the same stamp to all three content members.
    private static func setContentStamp(_ entity: inout Phi_PhiURLRuleEntity, _ stamp: Int64) {
        entity.host.updatedAtMs = stamp
        entity.pathPrefix.updatedAtMs = stamp
        entity.ask.updatedAtMs = stamp
    }

    /// Preserve the baseline stamp when value signatures match; otherwise use `now`.
    private static func restamped(_ value: Phi_PhiSettingValue,
                                  _ baseline: Phi_PhiSettingValue,
                                  _ now: Int64) -> Int64 {
        SyncableSettings.signature(of: value) == SyncableSettings.signature(of: baseline)
            ? baseline.updatedAtMs : now
    }

    private static func mergedSource(_ left: Int32, _ right: Int32) -> Int32 {
        if left == 0 { return right }
        if right == 0 { return left }
        return min(left, right)
    }

    /// Merge creation time by preferring a nonzero value, or the earlier of two nonzero values.
    /// Shared by merge and stamping (R-exec-16).
    private static func mergedCreatedAtMs(_ left: Int64, _ right: Int64) -> Int64 {
        [left, right].filter { $0 > 0 }.min() ?? 0
    }

    /// Validate the shape of an account identity, following bookmarks. Deliberately avoid RFC-4122
    /// validation: reject device-local ids, without prescribing the peer's UUID generator. Keep
    /// this limited predicate private rather than exposing it as a general validation API.
    private static func isAccountUuid(_ uuid: String) -> Bool {
        !uuid.isEmpty
            && !uuid.contains(where: { $0.isUppercase })
            && !uuid.contains(where: { $0.isWhitespace || $0.isNewline })
    }

    private static func string(_ value: String) -> Phi_PhiSettingValue {
        var out = Phi_PhiSettingValue()
        out.stringValue = value
        return out
    }

    private static func bool(_ value: Bool) -> Phi_PhiSettingValue {
        var out = Phi_PhiSettingValue()
        out.boolValue = value
        return out
    }

    /// Round milliseconds, as bookmarks do; truncation can differ by 1 ms across devices and
    /// recreate the R-19 republish loop.
    private static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }
}

// MARK: - D30 signatures and at-rest predicates (§8.4.1)

/// Rule merge signature (§8.4.1 / R-M3-4a-52). Normalize all three members with §8.1's fixed-point
/// function. Exclude ask and rank (D30), but include target: the same host routed to different
/// Spaces is a conflict, not a duplicate. Keep both rules and resolve routing with §9's tie-break
/// key.
struct RuleSignature: Hashable {
    let host: String
    /// nil and a root-only slash are distinct values.
    let pathPrefix: String?
    /// An account-level value: the resolved Space syncUuid, or a reserved default/incognito
    /// constant. Never use local `spaceId`: RR3-6 compares this key against inbound
    /// `target_space_uuid`, and a different key space would silently disable claiming.
    let owner: String
}

/// 8b-2 ordering extension leaves the 8b-1 type definition unchanged. Both convergence and pointer
/// passes sort group keys, following pin convergence; dictionary iteration is randomized per
/// process and otherwise produces device/run-dependent operation order. The comparison is
/// injective: distinguish missing path from empty path before comparing values, so distinct
/// signatures never compare equal.
extension RuleSignature: Comparable {
    static func < (lhs: RuleSignature, rhs: RuleSignature) -> Bool {
        (lhs.host, lhs.pathPrefix == nil ? 0 : 1, lhs.pathPrefix ?? "", lhs.owner)
            < (rhs.host, rhs.pathPrefix == nil ? 0 : 1, rhs.pathPrefix ?? "", rhs.owner)
    }
}

extension URLRuleKind {
    /// §8.4.1 rule 1: apply both gates together (RR7-2): resolve an eligibility owner, then require
    /// `localSpaceId(owner) == nil || isEligibleSpace(owner)`, matching snapshot's second gate.
    /// Failure makes the row inert: exclude it from groups, M1/M2/M3, and snapshots. Never
    /// substitute a fallback owner such as nil, empty string, or local id: different targets could
    /// collapse into one group, soft-deleting an unpublished row that cannot even emit a tombstone.
    /// Inject normalization rather than reaching into storage. Normalize the row here too: V11
    /// backfilled rows may be noncanonical (M-8's `GitHub.com.`), while idempotence preserves
    /// already normalized values.
    static func signature(of row: PhiLocalURLRule, resolve: OwnerResolver,
                          normalize: (String, String?) -> (host: String, pathPrefix: String?))
        -> RuleSignature? {
        guard let owner = eligibilityOwner(of: row, resolve: resolve, scope: nil) else { return nil }
        return signature(host: row.host, pathPrefix: row.pathPrefix, owner: owner,
                         resolve: resolve, normalize: normalize)
    }

    /// The same signature rule for entities: read account ownership directly from
    /// `target_space_uuid` and map wire empty path to local nil (§8.1). Empty target or a failed
    /// second gate returns nil.
    static func signature(of entity: Phi_PhiURLRuleEntity, resolve: OwnerResolver,
                          normalize: (String, String?) -> (host: String, pathPrefix: String?))
        -> RuleSignature? {
        let wirePath = entity.pathPrefix.stringValue
        return signature(host: entity.host.stringValue,
                         pathPrefix: wirePath.isEmpty ? nil : wirePath,
                         owner: entity.targetSpaceUuid.stringValue,
                         resolve: resolve, normalize: normalize)
    }

    /// §8.4.1 rule 2: decode the cursor's `reconciled` entity and derive its signature through the
    /// shared entity helper. This is the signature before the local edit, used by M3 fallback
    /// lookup. Missing cursor/baseline, decode failure, empty target, or failed eligibility returns
    /// nil with no fallback. Sharing the implementation prevents divergent predicates (M-30(e)).
    static func baselineSignature(identity: String, table: PhiOwnedItemTable,
                                  resolve: OwnerResolver,
                                  normalize: (String, String?)
                                      -> (host: String, pathPrefix: String?)) -> RuleSignature? {
        guard let bytes = table.cursors[identity]?.reconciled,
              let envelope = try? Phi_PhiEntity(serializedBytes: bytes),
              let entity = entity(from: envelope) else { return nil }
        return signature(of: entity, resolve: resolve, normalize: normalize)
    }

    /// §8.4.1 rule 3: at rest means all ten predicates, evaluated in spec order. M2 grouping,
    /// winner selection, and §8.4.4 partner eligibility share this implementation.
    /// Only rows with `syncId` can qualify: it addresses predicate 1 and orders winners. Exclude
    /// missed V11 backfills without force-unwrapping. Predicates 1/2/3/4/5/9 read cursors; 6/7 read
    /// rows; 8 uses the resolver; 10 uses this page's arrivals. Compute once per page during
    /// pre-pass, using that page's inclusive read and current table. Later writes on the same page
    /// do not alter that captured decision (R-62).
    static func isAtRest(row: PhiLocalURLRule, cursor: PhiOwnedItemCursor?,
                         resolve: OwnerResolver,
                         normalize: (String, String?) -> (host: String, pathPrefix: String?),
                         tombstonesThisPage: Set<String>) -> Bool {
        guard let syncId = row.syncId else { return false }
        // 1. Published (R-23): unpublished rows have no account copy to compare.
        guard let cursor, cursor.server != nil else { return false }
        // 2. Account and landed copies match; an unpublished divergence is not at rest.
        guard cursor.server == cursor.reconciled else { return false }
        // 3. No parked inbound entity that would change the row on landing.
        guard cursor.pendingApply == nil else { return false }
        // 4. No pending local deletion that will remove the row next round.
        guard !cursor.pendingDelete else { return false }
        // 5. No parked remote tombstone (RR8-3). Otherwise a chosen winner could absorb every loser
        // and then itself be deleted, losing the whole group.
        guard !cursor.pendingTombstone else { return false }
        // 6. No unpublished user edit (R-65); that intent is not yet represented on the account.
        guard !row.pendingLocalEdit else { return false }
        // 7. Live row: soft-deleted rows neither converge nor serve as merge partners.
        guard row.deletedDate == nil else { return false }
        // 8. Valid signature passing both gates; inert rows belong to no group.
        guard signature(of: row, resolve: resolve, normalize: normalize) != nil else { return false }
        // 9. Not awaiting R-exec-13 identity repair, matching the engine's unkeyed predicate. Such
        // a cursor must recover its identity through client tag; eliminating it would bypass
        // abandonment accounting.
        guard !(cursor.entityId.isEmpty && cursor.reconciled != nil) else { return false }
        // 10. No inbound tombstone for this identity on this page (R-86). Earlier predicates cannot
        // see a newly arrived deletion. Transferring into W before deleting W in the same
        // transaction would lose the edit. This complements predicate 5's already parked
        // tombstones.
        guard !tombstonesThisPage.contains(syncId) else { return false }
        return true
    }

    /// Shared signature finalization: reject empty targets and mapped but ineligible owners.
    /// Reserved constants intentionally have no local mapping (R-7), so they pass the second
    /// condition.
    private static func signature(host: String, pathPrefix: String?, owner: String,
                                  resolve: OwnerResolver,
                                  normalize: (String, String?) -> (host: String, pathPrefix: String?))
        -> RuleSignature? {
        guard !owner.isEmpty else { return nil }
        if resolve.localSpaceId(owner) != nil, !resolve.isEligibleSpace(owner) { return nil }
        let normalized = normalize(host, pathPrefix)
        return RuleSignature(host: normalized.host, pathPrefix: normalized.pathPrefix, owner: owner)
    }
}

// MARK: - D30 M2 pointer passes and whole-group reduction (§8.4.3, 8b-2)

/// Current effective account stamps per merge unit: content and target (R-97 / 98). M2 reads
/// content only; transfer reads both. Each stamp may independently be absent.
struct URLRuleEffectiveStamps: Equatable, Sendable {
    var content: Date?
    var target: Date?
}

/// §8.4.3 step 2(a): the winner absorbs a source content group in one write, including all three
/// fields and their shared stamp (R-48). At most one write per group (R-82).
struct RuleContentGroupWrite: Equatable {
    var syncId: String
    var host: String
    var pathPrefix: String?
    var ask: Bool
    var contentUpdatedDate: Date
}

/// §8.4.3 step 2(b): soft-delete a loser. Deletion time and merge partner are one row write
/// (RR8-4), represented together rather than as separate operations.
struct RuleSoftDelete: Equatable {
    var syncId: String
    var mergePartnerSyncId: String
}

/// Output of `convergePass`.
struct URLRuleConvergence: Equatable {
    /// At most one write per group (R-82): reduce the whole group instead of comparing each loser
    /// against a fixed winner snapshot.
    var contentGroupWrites: [RuleContentGroupWrite] = []
    var softDeletes: [RuleSoftDelete] = []
    /// Lifecycle row 3, clearing rule 1: clear the partner when at rest with no other live member
    /// in the signature group.
    var clearedPartners: [String] = []
    /// Count only losers actually soft-deleted (R-54).
    var collapsed = 0
    /// Step (c): include every bucket a loser leaves in this page's dense-order projection.
    var touchedBuckets: Set<String> = []
}

/// Pure §8.4.4 transfer decision (8b-3 / ruling 9), shared by the storage body and fake access so
/// winner selection cannot diverge.
struct URLRuleTransferDecision: Equatable {
    /// True when the entire content group wins: host/path/ask and their shared stamp.
    var writesContent = false
    /// True when the target unit wins: local Space id and target stamp.
    var writesTarget = false
    /// Number of units actually written (0–2). Only a positive count sets `pendingLocalEdit` and
    /// increments `transferred`; a zero-unit transfer must not leave W with a flag that never
    /// clears (§8.4.5).
    var written: Int { (writesContent ? 1 : 0) + (writesTarget ? 1 : 0) }
    /// Losing the content group counts one `superseded_by_delete` (§13.3).
    var contentSuperseded: Bool { !writesContent }
}

/// Complete merge-tail result.
struct URLRuleMergeResult {
    var ops: [URLRuleSyncOp] = []
    var collapsed = 0
    var touchedBuckets: Set<String> = []
    /// True for soft deletion or a content-group write; false for pointer-only writes. Merge
    /// partners are absent from routing, so refreshing for them is unnecessary (M-7 asserts zero
    /// refreshes).
    var changedRouting = false
}

extension URLRuleKind {
    /// The sole internal normalization reference beyond the three injection sites (§8.4.1). M2's
    /// specified pure-function signatures omit a normalizer argument, but grouping must use the
    /// same fixed point as `signatureIndex` / `mergePartners`. This alias binds all paths to one
    /// implementation, mirroring the shared at-rest predicate.
    private static var mergeNormalize: (String, String?) -> (host: String, pathPrefix: String?) {
        URLRuleSignatureQueries.normalize
    }

    /// Milliseconds to Date, inverse of `milliseconds`. Treat zero as absent: interpreting a
    /// missing no-baseline edit stamp as 1970 would incorrectly turn it into a real, very old LWW
    /// timestamp (R-12).
    private static func stampDate(_ ms: Int64) -> Date? {
        ms == 0 ? nil : Date(timeIntervalSince1970: Double(ms) / 1000)
    }

    /// Identities landed from the account on this page (R-74(1)), filtered by step kind.
    /// `outcome.landed` is a superset: it also covers deletion identities and 8b-3(β)'s transfer
    /// cleanup. Never substitute that set (RR12-6).
    /// Include claims: the row receives its first account identity/rank on this page and represents
    /// an account entity locally, just like creation. Pointer-anchor selection must recognize it.
    static func landedIdentities(in steps: [OwnedItemApplyStep]) -> Set<String> {
        var out: Set<String> = []
        for step in steps {
            switch step.kind {
            case .claim, .create, .move, .update:
                out.insert(step.identity)
            case .transfer, .delete:
                // Exclude transfer: it writes W's local row without landing an account entity for
                // this identity. Branch (β) returns `outcome.landed` only to clear the pending
                // payload (ruling 8); that superset is not interchangeable with this set (RR12-6).
                continue
            }
        }
        return out
    }

    /// Target identities of this page's transfer phase, third of four phases (R-M3-4a-93 /
    /// R-M3-4a-90). Subtract them from M2 step 2 candidates (ruling 6(1)). Derive them from the
    /// same steps and land closure as landedIdentities, without another data channel.
    ///
    /// The exact set contains targets where transferURLRuleEditBody wrote at least one unit. This
    /// pure function returns a safe superset: all transfer targets. At worst it defers a group's
    /// convergence until another page. Without the exclusion, this page's M2 tail hook can
    /// overwrite an edit just transferred into W using pre-application stamps (CASE M-33).
    static func transferTargets(in steps: [OwnedItemApplyStep]) -> Set<String> {
        Set(steps.compactMap { step -> String? in
            switch step.kind {
            case .transfer(_, let to):
                return to
            case .claim, .create, .move, .update, .delete:
                return nil
            }
        })
    }

    /// Comparable millisecond timestamps (R-M3-4a-102 / ruling 11). Account stamps use
    /// milliseconds, while rows use Date; direct Date comparison can mistake submillisecond
    /// differences for edits and needlessly park a round. Normalize both sides before comparing.
    static func stampMilliseconds(_ date: Date?) -> Int64? {
        date.map { milliseconds($0) }
    }

    // MARK: - Shared row projection for both §8.4.5 flag-clearing paths (8b-4)

    /// Both §8.4.5 clearing paths compare the row's current three merge units, not decoded payload
    /// bytes (ruling 2).
    ///
    /// Both use this function. The urlRules snapshot closure records path a's baseline while
    /// producing snapshot.entities[identity], in URLRuleSyncRoundState.publishBaseline; path b
    /// reads that same record (R-M3-4a-91 / 96), without a second channel. LocalStore recomputes
    /// the current side from the reread row inside each clearing transaction.
    ///
    /// The target unit uses local spaceId (ruling 4), matching transferURLRuleEditBody's
    /// source.targetSpaceId. LocalStore knows no account mappings, so targetOwnerUuid stays empty
    /// and clearingProjectionMatches ignores it.
    ///
    /// Carry all three stamps unchanged and convert to milliseconds only during comparison. Rows
    /// use submillisecond Date values while account stamps use Int64 milliseconds; truncating here
    /// would make the projections disagree with one another.
    static func clearingProjection(of row: PhiLocalURLRule) -> RuleProjection {
        let normalize = mergeNormalize
        let normalized = normalize(row.host, row.pathPrefix)
        return RuleProjection(host: normalized.host,
                              pathPrefix: normalized.pathPrefix,
                              askBeforeRouting: row.askBeforeRouting,
                              contentUpdatedDate: row.contentUpdatedDate,
                              targetOwnerUuid: "",
                              targetSpaceId: row.spaceId,
                              targetUpdatedDate: row.targetUpdatedDate,
                              sortOrder: row.sortOrder)
    }

    /// Compare the three merge units individually at millisecond precision (ruling 2).
    ///
    /// A confirmed projection missing target or sortOrder never matches (fail-closed, rulings 3/4).
    /// Entity-derived transferSource projections can lack either; using one as a clearing baseline
    /// must mean unavailable, therefore do not clear, rather than accidentally clearing an
    /// unpublished edit.
    ///
    /// Ignore targetOwnerUuid (ruling 4): both clearing projections come from rows and leave it
    /// empty.
    static func clearingProjectionMatches(row: RuleProjection, confirmed: RuleProjection) -> Bool {
        guard row.host == confirmed.host,
              row.pathPrefix == confirmed.pathPrefix,
              row.askBeforeRouting == confirmed.askBeforeRouting,
              stampMilliseconds(row.contentUpdatedDate)
                  == stampMilliseconds(confirmed.contentUpdatedDate)
        else { return false }
        guard let targetSpaceId = confirmed.targetSpaceId,
              row.targetSpaceId == targetSpaceId,
              stampMilliseconds(row.targetUpdatedDate)
                  == stampMilliseconds(confirmed.targetUpdatedDate)
        else { return false }
        guard let sortOrder = confirmed.sortOrder, row.sortOrder == sortOrder else { return false }
        return true
    }

    /// Transaction-local recheck that row X still matches the operation's source (R-M3-4a-102 /
    /// ruling 11).
    ///
    /// Do not compare all six cells for exact equality. Source timestamps come from a baselined
    /// local projection: unchanged units reuse baseline stamps, not the possibly nil row columns.
    /// Comparing row stamps directly would permanently park M-12 branch i, where only target
    /// changed and content did not.
    ///
    /// Require both signatures of a real editor Save:
    /// 1. All four values match: host, pathPrefix, askBeforeRouting, and spaceId.
    /// applyURLRuleEditsBody steps 4/5 write only changed units, so an effective Save changes at
    /// least one value.
    /// 2. Neither row edit stamp is newer than its source counterpart, at millisecond precision.
    /// Save stamps now; this catches A→B→A edits whose final values match.
    ///
    /// A missing or soft-deleted row always counts as changed. M2 may just have soft-deleted X as a
    /// loser in the same transaction; its tombstone then belongs to β, not α.
    static func transferSourceUnchanged(row: PhiLocalURLRule?, source: RuleProjection) -> Bool {
        guard let row, row.deletedDate == nil else { return false }
        let normalize = mergeNormalize
        let rowContent = normalize(row.host, row.pathPrefix)
        let sourceContent = normalize(source.host, source.pathPrefix)
        guard rowContent.host == sourceContent.host,
              rowContent.pathPrefix == sourceContent.pathPrefix,
              row.askBeforeRouting == source.askBeforeRouting,
              row.spaceId == source.targetSpaceId else { return false }
        if let rowStamp = stampMilliseconds(row.contentUpdatedDate),
           rowStamp > (stampMilliseconds(source.contentUpdatedDate) ?? Int64.min) {
            return false
        }
        if let rowStamp = stampMilliseconds(row.targetUpdatedDate),
           rowStamp > (stampMilliseconds(source.targetUpdatedDate) ?? Int64.min) {
            return false
        }
        return true
    }

    /// Transfer compares W's current merge units by LWW and writes only whole winning groups
    /// (§8.4.4 / ruling 9).
    ///
    /// For each W unit, use max(row stamp, effective account stamp) (R-M3-4a-98). Row stamps can
    /// lag or be nil because rebaselining does not update rows; reading them alone can overwrite
    /// newer account values, and phase ordering cannot help if this page has no update for W.
    /// Taking the maximum also preserves earlier same-page transfers that updated only the row.
    ///
    /// Content: host/path_prefix/ask share host's group stamp. If it wins, copy all three fields
    /// and the source stamp without minting now. Transferring only ask with X's stamp would falsely
    /// advance W's unchanged host/path and defeat intervening remote edits (D15 / R-M3-4a-40).
    /// Target: copy source.targetSpaceId and its stamp together if it wins; a nil local target
    /// skips the group.
    /// Rank: neither compare nor transfer it; it represents position.
    /// Treat missing stamps as distantPast: nil and ties never win, and missing values produce no
    /// writes.
    static func transferDecision(target: PhiLocalURLRule, source: RuleProjection,
                                 targetEffectiveStamps: URLRuleEffectiveStamps)
        -> URLRuleTransferDecision {
        var out = URLRuleTransferDecision()
        let sourceContent = source.contentUpdatedDate ?? .distantPast
        let targetContent = latest(target.contentUpdatedDate, targetEffectiveStamps.content)
        out.writesContent = sourceContent > targetContent
        if source.targetSpaceId != nil {
            let sourceTarget = source.targetUpdatedDate ?? .distantPast
            let targetTarget = latest(target.targetUpdatedDate, targetEffectiveStamps.target)
            out.writesTarget = sourceTarget > targetTarget
        }
        return out
    }

    /// Either max operand may be nil; if both are nil, return distantPast.
    private static func latest(_ left: Date?, _ right: Date?) -> Date {
        max(left ?? .distantPast, right ?? .distantPast)
    }

    /// The sole source of merge-unit stamps is effective account state after this page's
    /// application (R-M3-4a-94), resolved per identity in this order:
    /// 1. landed values for create/move/update targets. Their stamps match the reconciled bytes
    /// about to be recorded; cursor bookkeeping still holds pre-application state until land
    /// returns.
    /// 2. New rebaselined bytes for unchanged values with newer stamps (R-M3-4a-97). The cursor is
    /// still older until land returns; omitting this layer fails CASE M-33(d).
    /// 3. The entity decoded from the cursor's reconciled baseline.
    ///
    /// Resolve each unit independently. A missing unit falls through to the next layer; if none
    /// supplies it, omit it from the result. convergePass treats absence as distantPast and never
    /// selects it as source. All layers treat zero milliseconds as absent (8b-2 fix round 1 / F3):
    /// layers 2/3 use stampDate, while landed nonoptional Dates require explicit suppression of
    /// Date(1970). R-M3-4a-12 deliberately stamps unbaselined target/rank at zero; it must not
    /// become a seemingly real old transfer stamp.
    ///
    /// Never read row.contentUpdatedDate. New rows retain nil under Task 5 ruling 5; publication
    /// falls back to createdDate and applied does not backfill. Rebaselining also changes only
    /// cursors. A quiescent account stamp of 30 may therefore correspond to local nil or 10,
    /// incorrectly losing to B@20; createdDate fallback would instead choose device-dependent
    /// sources. Quiescence implies a baseline with server == reconciled, not equal row and baseline
    /// stamps.
    static func effectiveAccountStamps(landed: [String: URLRuleLandingValues],
                                       rebaselined: [String: Data],
                                       table: PhiOwnedItemTable,
                                       identities: Set<String>)
        -> [String: URLRuleEffectiveStamps] {
        var out: [String: URLRuleEffectiveStamps] = [:]
        for identity in identities {
            var stamps = URLRuleEffectiveStamps()
            // Layer 1: URLRuleLandingValues stamps are nonoptional Dates. R-M3-4a-12's unbaselined
            // zero target/rank becomes Date(1970), which means absence rather than a real old stamp
            // (8b-2 fix round 1 / F3). Suppress zero consistently with stampDate in layers 2/3.
            // Missing units are omitted: convergence treats them as distantPast and never as
            // source; transfer uses the other max operand.
            if let values = landed[identity] {
                stamps.content = suppressingEpoch(values.contentUpdatedDate)
                stamps.target = suppressingEpoch(values.targetUpdatedDate)
            }
            // Layer 2 precedes layer 3: rebaselined contains the bytes the cursor will hold after
            // this page. Fill missing units independently after layer-1 zero suppression. A newly
            // created identity may have no cursor fallback, leaving that unit absent.
            if stamps.content == nil || stamps.target == nil,
               let bytes = rebaselined[identity] ?? table.cursors[identity]?.reconciled,
               let envelope = try? Phi_PhiEntity(serializedBytes: bytes),
               let entity = entity(from: envelope) {
                if stamps.content == nil { stamps.content = stampDate(entity.host.updatedAtMs) }
                if stamps.target == nil {
                    stamps.target = stampDate(entity.targetSpaceUuid.updatedAtMs)
                }
            }
            guard stamps.content != nil || stamps.target != nil else { continue }
            out[identity] = stamps
        }
        return out
    }

    /// The instant represented by zero milliseconds means absent, not an actual timestamp in 1970.
    private static func suppressingEpoch(_ date: Date) -> Date? {
        date.timeIntervalSince1970 == 0 ? nil : date
    }

    /// Run both §8.4.3 step-1 pointer passes on every page, independently of hasDrainedFullReplay
    /// (R-M3-4a-74(3) / RR11-1). Return identity-to-anchor entries only for necessary row writes.
    ///
    /// liveRows contains all rows without deletedDate, including unsigned rows: they cannot join
    /// groups, but dangling-pointer detection must consider every live identity. Both passes group
    /// over all live rows (RR12-1). Pass 1 uses current signatures; pass 2 uses
    /// preLandingSignatures[id] with current signature fallback. Omit rows with neither.
    ///
    /// Choose the lowest syncId only among published live members plus landedThisPage, and write
    /// nothing if that subset has fewer than two members. A smaller unpublished identity must not
    /// anchor the group: it never becomes quiescent for §8.4.4 lookup (RR13-5). publishedIdentities
    /// is explicit (R-M3-4a-95), because M1 can assign syncId before publication produces a server
    /// tuple.
    ///
    /// anchorRows supplies pass 1's anchor subset independently of the write domain (8b-2 fix round
    /// 1). The tail hook provides live rows before soft deletion; liveRows is after deletion. The
    /// spec tests subset size before convergence: two published members plus one unpublished row
    /// must still give the unpublished survivor a pointer, even if convergence leaves only one
    /// published row (RR10-8). nil uses liveRows.
    ///
    /// Pass 2 instead derives anchors and subset size from post-deletion liveRows (fix round 2).
    /// The proof that anchor ≤ winner < every loser relies on sharing convergePass's
    /// current-signature key, which only pass 1 does. A loser deleted under K1 could rejoin K2
    /// under its pre-application signature and become K2's smallest id, creating pointers to a row
    /// just soft-deleted in the same transaction; that dead row may even be what raises K2's subset
    /// size to two. This is reachable because a moved/updated row can retain pre-pass quiescence
    /// and be selected as a loser. The spec likewise runs pass 2 over liveAfter.
    ///
    /// Required write precondition (RR12-7): update only live members whose pointer is nil or
    /// references no live local identity. Preserve pointers to live rows. Update the function's
    /// pointer state after each emitted write so pass 2 cannot overwrite pass 1. The storage
    /// primitive's unchanged-value no-op is secondary defense, not this guarantee.
    static func mergePointerPass(liveRows: [PhiLocalURLRule],
                                 anchorRows: [PhiLocalURLRule]? = nil,
                                 landedThisPage: Set<String>,
                                 publishedIdentities: Set<String>,
                                 preLandingSignatures: [String: RuleSignature],
                                 resolve: OwnerResolver) -> [String: String] {
        let normalize = mergeNormalize
        // Anchor-subset domain; nil shares the write-loop domain, as usual for pure-value callers.
        let anchorDomain = anchorRows ?? liveRows
        // Dangling-pointer checks use every live identity, including rows without signatures.
        var liveIdentities: Set<String> = []
        // Track each identity's current pointer, updating it as this function emits writes.
        var pointer: [String: String] = [:]
        for row in liveRows {
            guard let identity = row.syncId else { continue }
            liveIdentities.insert(identity)
            if let partner = row.mergePartnerSyncId { pointer[identity] = partner }
        }

        var out: [String: String] = [:]
        /// anchorsFrom is this pass's anchor-subset and cardinality domain: pre-deletion live rows
        /// for pass 1, post-deletion live rows for pass 2. See anchorRows above.
        func pass(_ keyOf: (PhiLocalURLRule) -> RuleSignature?,
                  anchorsFrom: [PhiLocalURLRule]) {
            var groups: [RuleSignature: [PhiLocalURLRule]] = [:]
            for row in liveRows where row.syncId != nil {
                guard let key = keyOf(row) else { continue }
                groups[key, default: []].append(row)
            }
            var anchorGroups: [RuleSignature: [String]] = [:]
            for row in anchorsFrom {
                guard let identity = row.syncId, let key = keyOf(row),
                      publishedIdentities.contains(identity)
                        || landedThisPage.contains(identity) else { continue }
                anchorGroups[key, default: []].append(identity)
            }
            // Use deterministic traversal, following PinKind.swift:361; dictionary-key order varies
            // by process.
            for key in groups.keys.sorted() {
                let members = (groups[key] ?? []).sorted { ($0.syncId ?? "") < ($1.syncId ?? "") }
                let anchors = (anchorGroups[key] ?? []).sorted()
                // Fewer than two anchor candidates means no writes; a lone anchor needs no partner
                // pointer.
                guard anchors.count >= 2, let anchor = anchors.first else { continue }
                for row in members {
                    guard let identity = row.syncId, identity != anchor else { continue }
                    // Required precondition: preserve any pointer already targeting a live row.
                    if let current = pointer[identity], liveIdentities.contains(current) { continue }
                    guard pointer[identity] != anchor else { continue }
                    out[identity] = anchor
                    pointer[identity] = anchor
                }
            }
        }
        // Pass 1 uses current signatures, matching convergePass, so compute subset size from the
        // pre-deletion live set at the point specified by the pseudocode.
        pass({ signature(of: $0, resolve: resolve, normalize: normalize) },
             anchorsFrom: anchorDomain)
        // Pass 2 uses pre-application signatures, so an anchor could have been a loser. Compute
        // both candidates and count from the post-deletion live set (fix round 2).
        pass({ row in
            if let identity = row.syncId, let key = preLandingSignatures[identity] { return key }
            return signature(of: row, resolve: resolve, normalize: normalize)
        }, anchorsFrom: liveRows)
        return out
    }

    /// §8.4.3 step 2, called only when convergeAllowed is true (caller-enforced, C-15). atRest has
    /// already had two exclusions: land removes this page's transfer targets (ruling 6(1) /
    /// R-M3-4a-90), then the transaction tail removes rows now edited, soft-deleted, or absent
    /// (ruling 6(3) / R-M3-4a-100). Use that set unchanged.
    /// accountStamps contains effectiveAccountStamps' content unit (R-M3-4a-94 / 97): landed
    /// values, then rebaselined bytes, then cursor baseline, never row columns. Omit identities
    /// without a content stamp.
    ///
    /// For each signature group, fewer than two quiescent members means no convergence. A sole
    /// live, quiescent member with a pointer enters clearedPartners (lifecycle row 3), without
    /// another read. Otherwise W is the lowest-syncId quiescent member.
    /// (a) Select one source from all quiescent members, including W, using greatest account stamp
    /// and lexicographic syncId for ties. Emit one RuleContentGroupWrite only when content differs
    /// or source is strictly newer. Reduce the whole group, never compare each loser against a
    /// fixed W snapshot; copy source stamps without minting now (R-M3-4a-82).
    /// (b) Soft-delete each loser with mergePartnerSyncId=W.syncId.
    /// (c) Record each vacated bucket in touchedBuckets. Preserve W's target and rank.
    static func convergePass(groups: [RuleSignature: [PhiLocalURLRule]],
                             atRest: Set<String>,
                             accountStamps: [String: Date]) -> URLRuleConvergence {
        let normalize = mergeNormalize
        var out = URLRuleConvergence()
        /// Comparable content group: normalize all three member values; legacy V11-backfilled rows
        /// were not normalized.
        func content(_ row: PhiLocalURLRule) -> (String, String?, Bool) {
            let normalized = normalize(row.host, row.pathPrefix)
            return (normalized.host, normalized.pathPrefix, row.askBeforeRouting)
        }
        func stamp(_ row: PhiLocalURLRule) -> Date? {
            row.syncId.flatMap { accountStamps[$0] }
        }

        for key in groups.keys.sorted() {
            let members = (groups[key] ?? []).sorted { ($0.syncId ?? "") < ($1.syncId ?? "") }
            let settled = members.filter { row in
                guard let identity = row.syncId else { return false }
                return atRest.contains(identity)
            }
            guard settled.count >= 2 else {
                // Clearing rule ① (RR9-4): the group has no second live row, not membership in no
                // signature group. The latter is impossible because quiescence criterion 8 requires
                // a signature.
                if members.count == 1, let row = members.first, let identity = row.syncId,
                   atRest.contains(identity), row.mergePartnerSyncId != nil {
                    out.clearedPartners.append(identity)
                }
                continue
            }
            // Winner: the quiescent member with the lowest syncId; settled is already sorted by it.
            guard let winner = settled.first, let winnerId = winner.syncId else { continue }
            // (a) Reduce the whole group to one source and one write. Break stamp ties by
            // lexicographic syncId so devices produce identical results.
            let source = settled.max { left, right in
                (stamp(left) ?? .distantPast, left.syncId ?? "")
                    < (stamp(right) ?? .distantPast, right.syncId ?? "")
            }
            if let source, let sourceStamp = stamp(source) {
                let winnerStamp = stamp(winner) ?? .distantPast
                if content(source) != content(winner) || sourceStamp > winnerStamp {
                    let normalized = normalize(source.host, source.pathPrefix)
                    out.contentGroupWrites.append(
                        RuleContentGroupWrite(syncId: winnerId,
                                              host: normalized.host,
                                              pathPrefix: normalized.pathPrefix,
                                              ask: source.askBeforeRouting,
                                              // D33 / §8.4.1 rule 5: copy the source timestamp;
                                              // never mint now.
                                              contentUpdatedDate: sourceStamp))
                }
            }
            // (b)/(c) always exclude settled.first. CASE M-5 prevents deleting every local member
            // of a signature group.
            for loser in settled.dropFirst() {
                guard let identity = loser.syncId else { continue }
                out.softDeletes.append(RuleSoftDelete(syncId: identity,
                                                      mergePartnerSyncId: winnerId))
                out.collapsed += 1
                out.touchedBuckets.insert(loser.spaceId)
            }
        }
        return out
    }

    /// Pure tail-hook computation: filter live rows, group by signature, compute
    /// effectiveAccountStamps (R-M3-4a-94 / 97), then remove currently edited, soft-deleted, or
    /// absent rows from atRest (R-M3-4a-100). rows was just reread in the transaction, so no
    /// additional fetch is needed. Run convergePass only if enabled, using content stamps; then run
    /// both mergePointerPass passes. Pointer writes use post-deletion live rows, with pre-deletion
    /// anchors for pass 1 and post-deletion anchors for pass 2. Emit setContentGroup, softDelete,
    /// then setMergePartner operations.
    ///
    /// Equivalence of convergence before both pointer passes (ruling 4): the spec interleaves pass
    /// 1 with per-group convergence and runs pass 2 over liveAfter. This order yields the same
    /// final state with fewer writes for three reasons.
    ///
    /// 1. Pass-1 anchor identity survives. The anchor is the minimum id among published live
    /// members plus landedThisPage; W is minimum among quiescent members. Quiescence implies
    /// publication (criteria 1/2), so anchor ≤ W < every loser. A quiescent anchor is W itself.
    /// Removing losers changes neither the anchor identity nor its row.
    ///
    /// 2. Preserve pass-1 anchor cardinality through the input boundary (fix rounds 1/2). The spec
    /// checks published.count > 1 before convergence. Two published members plus an unpublished,
    /// unapplied row would otherwise shrink to one published member and lose the pointer the spec
    /// assigns to that unpublished survivor (RR10-8). Supply pre-deletion anchorRows for pass 1
    /// while writing only post-deletion liveRows.
    /// Pass 2 cannot reuse that domain: its pre-application signature keys differ from
    /// convergence's keys. A loser deleted under K1 can become the smallest-id anchor under old K2,
    /// producing a pointer to a dead row; it may also be the member that makes K2 reach size two.
    /// Derive pass-2 candidates and count from liveRows, matching the spec's liveAfter.
    ///
    /// 3. Final values take precedence. The spec may first point a loser at the anchor and then
    /// overwrite it with W during soft deletion. Here losers are excluded from pointer writes,
    /// leaving the same W result. Nonlosers receive equivalent inputs. RR11-2's prohibition on
    /// overwriting the deletion's final pointer is therefore structural, without a runtime check.
    ///
    /// table, landed, and rebaselined serve only effectiveAccountStamps. R-M3-4a-94 restored table,
    /// removed by R-M3-4a-90, because nonlanded stamps require cursor baselines; R-M3-4a-97 added
    /// rebaselined as layer 2. convergePass receives computed stamps and must never inspect table.
    /// publishedIdentities serves only anchor selection (R-M3-4a-95). atRest is an upper bound:
    /// land already excluded transfer targets, and this function narrows it again inside the
    /// transaction.
    static func mergePass(rows: [PhiLocalURLRule],
                          landedThisPage: Set<String>,
                          publishedIdentities: Set<String>,
                          preLandingSignatures: [String: RuleSignature],
                          atRest: Set<String>,
                          landed: [String: URLRuleLandingValues],
                          rebaselined: [String: Data],
                          table: PhiOwnedItemTable,
                          convergeAllowed: Bool,
                          resolve: OwnerResolver) -> URLRuleMergeResult {
        let normalize = mergeNormalize
        var out = URLRuleMergeResult()
        // Use allURLRules' live-row predicate (R-M3-4a-51): a just-deleted row cannot be a member
        // (CASE M-10). Input still includes soft-deleted rows because addressing requires them.
        let live = rows.filter { $0.deletedDate == nil }

        var groups: [RuleSignature: [PhiLocalURLRule]] = [:]
        for row in live where row.syncId != nil {
            guard let key = signature(of: row, resolve: resolve, normalize: normalize) else {
                continue
            }
            groups[key, default: []].append(row)
        }

        // R-M3-4a-100's second subtraction only removes candidates. Never re-add a row rejected by
        // pre-pass merely because it now looks clean; that bypasses cursor-side criteria and
        // criterion 10 (CASE M-27 / M-36). These three checks are exactly the row-only criteria
        // among the ten, already present in the reread projection.
        var rowOf: [String: PhiLocalURLRule] = [:]
        for row in rows {
            guard let identity = row.syncId else { continue }
            if row.deletedDate == nil || rowOf[identity] == nil { rowOf[identity] = row }
        }
        let candidates = atRest.filter { identity in
            guard let row = rowOf[identity] else { return false }   // The row no longer exists.
            return !row.pendingLocalEdit && row.deletedDate == nil
        }

        // Tail-hook copy of this page's effective-stamp table. Identical pure-function inputs
        // guarantee agreement with the table computed before land assembles the batch, satisfying
        // R-M3-4a-98's same-table requirement.
        var asked: Set<String> = landedThisPage
        for members in groups.values {
            for row in members { if let identity = row.syncId { asked.insert(identity) } }
        }
        let stamps = effectiveAccountStamps(landed: landed, rebaselined: rebaselined,
                                            table: table, identities: asked)
        var contentStamps: [String: Date] = [:]
        for (identity, pair) in stamps {
            if let content = pair.content { contentStamps[identity] = content }
        }

        // C-15: the gate controls only step 2. Step-1 pointers and the preceding stamp lookup run
        // regardless.
        let convergence = convergeAllowed
            ? convergePass(groups: groups, atRest: candidates, accountStamps: contentStamps)
            : URLRuleConvergence()

        // Ruling 4: pointer writes use the post-deletion live set. Content-group writes preserve
        // signatures: ask is excluded, and host/pathPrefix become the group's shared normalized
        // values. Only remove losers here.
        let collapsedIds = Set(convergence.softDeletes.map(\.syncId))
        let liveAfter = live.filter { row in
            guard let identity = row.syncId else { return true }
            return !collapsedIds.contains(identity)
        }
        // Write over the post-deletion live set; pass 1's anchor subset uses the pre-deletion set,
        // preserving equivalence argument 2.
        let pointers = mergePointerPass(liveRows: liveAfter, anchorRows: live,
                                        landedThisPage: landedThisPage,
                                        publishedIdentities: publishedIdentities,
                                        preLandingSignatures: preLandingSignatures,
                                        resolve: resolve)

        // Operation order: setContentGroup, softDelete, setMergePartner. Emit rule-① pointer clears
        // before pointer assignments: if an identity is a singleton in pass 1 but joins a larger
        // old-signature group in pass 2, the later assignment is the final value.
        for write in convergence.contentGroupWrites.sorted(by: { $0.syncId < $1.syncId }) {
            out.ops.append(.setContentGroup(syncId: write.syncId, host: write.host,
                                            pathPrefix: write.pathPrefix, ask: write.ask,
                                            contentUpdatedDate: write.contentUpdatedDate))
        }
        for delete in convergence.softDeletes.sorted(by: { $0.syncId < $1.syncId }) {
            out.ops.append(.softDelete(syncId: delete.syncId,
                                       mergePartnerSyncId: delete.mergePartnerSyncId))
        }
        for identity in convergence.clearedPartners.sorted() {
            out.ops.append(.setMergePartner(syncId: identity, mergePartnerSyncId: nil))
        }
        for identity in pointers.keys.sorted() {
            out.ops.append(.setMergePartner(syncId: identity, mergePartnerSyncId: pointers[identity]))
        }

        out.collapsed = convergence.collapsed
        out.touchedBuckets = convergence.touchedBuckets
        // §6.6 row 8 trigger: pointer writes do not count; CASE M-7 asserts no refresh.
        out.changedRouting = !convergence.softDeletes.isEmpty
            || !convergence.contentGroupWrites.isEmpty
        return out
    }
}

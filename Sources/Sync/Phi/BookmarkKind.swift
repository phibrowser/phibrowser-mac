// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

// Bookmark/folder adapter: codec, field LWW, owner resolution and timestamps. Sole implementation of §4.3's
// position = location + rank. Root location groups space_uuid and parent_uuid under one timestamp, with
// authoritative space_uuid. Descendant location uses parent_uuid alone; space_uuid is diagnostic and ignored
// by receivers. Rank remains independent with its own timestamp in both cases.

enum BookmarkKind: OwnedItemKind {
    typealias Entity = Phi_PhiBookmarkEntity
    typealias Local = PhiLocalBookmark

    static var tagPrefix: String { PhiSyncEntity.bookmarkTagPrefix }
    static var entityName: String { PhiSyncEntity.bookmarkEntityName }

    // MARK: - Identity and envelope

    static func identity(of entity: Phi_PhiBookmarkEntity) -> String { entity.bookmarkUuid }

    /// Account identity is local syncId. Nil means no identity minted yet; §6 rule (i) can still claim it.
    /// Exclude it only from this round's publication, not from claiming.
    static func identity(of local: PhiLocalBookmark, resolve: OwnerResolver,
                         scope: PinnedTabScope?) -> String? {
        local.syncId
    }

    static func envelope(_ entity: Phi_PhiBookmarkEntity) -> Phi_PhiEntity {
        var out = Phi_PhiEntity()
        out.bookmark = entity
        return out
    }

    static func entity(from envelope: Phi_PhiEntity) -> Phi_PhiBookmarkEntity? {
        guard case .bookmark(let payload)? = envelope.kind else { return nil }
        return payload
    }

    static func localEdge(of local: PhiLocalBookmark) -> (id: String, parentId: String?) {
        (id: local.guid, parentId: local.parentGuid)
    }

    /// Translate the row's containing Space to account syncUuid, or nil if unmapped. Unlike ownerUuids, this
    /// must not return a descendant's parent: isEligibleSpace would accept that parent and keep publishing
    /// rows beneath an account-deleted Space throughout its 30-day local retention until cascade purge.
    static func eligibilityOwner(of local: PhiLocalBookmark, resolve: OwnerResolver,
                                 scope: PinnedTabScope?) -> String? {
        resolve.syncUuid(local.spaceId)
    }

    // MARK: - Ownership

    /// Owner reference that must resolve before landing: parent_uuid for descendants, space_uuid for roots.
    /// Never require descendant space_uuid: this diagnostic field is ignored and never republished
    /// (R-M3-3-18), so it retains the pre-move Space. Requiring it would permanently park a moved subtree on
    /// new devices after its former Space is deleted.
    static func ownerUuids(of entity: Phi_PhiBookmarkEntity) -> [String] {
        let parent = entity.parentUuid.stringValue
        if !parent.isEmpty { return [parent] }
        let space = entity.spaceUuid.stringValue
        return space.isEmpty ? [] : [space]
    }

    // MARK: - Outbound projection and timestamps (§4.2)

    /// Project local row to wire entity without timestamps or rank. Return nil if the Space is unmapped (first
    /// excluded_unmapped_owner case) or its parent is not sync-eligible this round (§4.2 item 2). Skip the
    /// whole row; never publish a fallback move to the Space root.
    static func project(_ local: PhiLocalBookmark, resolve: OwnerResolver,
                        scope: PinnedTabScope?, parentIdentity: String?) -> Phi_PhiBookmarkEntity? {
        guard let spaceUuid = resolve.syncUuid(local.spaceId) else { return nil }
        if local.parentGuid != nil && parentIdentity == nil { return nil }

        var entity = Phi_PhiBookmarkEntity()
        entity.bookmarkUuid = local.syncId ?? ""
        entity.spaceUuid = string(spaceUuid)
        entity.parentUuid = string(parentIdentity ?? "")
        entity.rank = string("")
        entity.isFolder = local.isFolder
        entity.title = string(local.title)
        entity.url = string(local.url.absoluteString)
        entity.secondaryURL = string(local.secondaryUrl?.absoluteString ?? "")
        entity.secondaryTitle = string(local.secondaryTitle ?? "")
        entity.source = Int32(truncatingIfNeeded: local.source)
        entity.createdAtMs = milliseconds(local.createdDate)
        return entity
    }

    static func rank(of entity: Phi_PhiBookmarkEntity) -> String { entity.rank.stringValue }

    /// Bytes of the four content values with timestamps zeroed, as in SyncableSettings.signature. Exclude
    /// location/rank, carried by move, to avoid empty content patches for pure moves. Comparing the whole
    /// entity would also treat remote restamping as content edits.
    static func contentSignature(of entity: Phi_PhiBookmarkEntity) -> Data {
        var out = Data()
        for value in [entity.title, entity.url, entity.secondaryURL, entity.secondaryTitle] {
            out.append(SyncableSettings.signature(of: value))
            out.append(0)
        }
        out.append(entity.isFolder ? 1 : 0)
        return out
    }

    /// Location timestamp carrier: space_uuid for roots, parent_uuid for descendants. Never take max: clients
    /// using different rules would disagree on winners and republish forever. Even malformed/older peers with
    /// unequal member stamps use the designated carrier without exceptions.
    static func locationStamp(of entity: Phi_PhiBookmarkEntity) -> Int64 {
        entity.parentUuid.stringValue.isEmpty
            ? entity.spaceUuid.updatedAtMs
            : entity.parentUuid.updatedAtMs
    }

    /// Stamping (§4.2 items 4/5): location members share now if location changes, never for reorder alone;
    /// rank has its own independent stamp; content fields compare signatures and stamp changed values
    /// individually.
    ///
    /// Without a baseline, stamp location/rank as 0 so derived local positions cannot outrank real remote
    /// actions. Content uses contentUpdatedDate ?? createdDate raised to `hlcMax + 1` (AM-1): the edit time
    /// is what the user meant, but a create or a post-yield republish has overwritten nothing, so the
    /// account's logical time is the floor.
    ///
    /// With a baseline, first merge created_at_ms and source too (R-exec-16); see below.
    ///
    /// C2: content fields carry their EDIT time (`contentUpdatedDate`), not the publish time. `now` is the
    /// round's hybrid-logical stamp and stays with location and rank, neither of which has an edit-date
    /// column yet (location gets one in Phase 2 / schema V13; rank stays on `now` by ruling Q-R2-5).
    static func stamp(_ projected: Phi_PhiBookmarkEntity, baseline: Phi_PhiBookmarkEntity?,
                      local: PhiLocalBookmark, rank: String, now: Int64,
                      hlcMax: Int64 = 0) -> Phi_PhiBookmarkEntity {
        var out = projected
        out.rank = string(rank)
        let contentStamp = milliseconds(local.contentUpdatedDate ?? local.createdDate)

        guard let baseline else {
            let created = PhiHybridClock.editStamp(editWallMs: contentStamp,
                                                   overwrittenStampMs: hlcMax)
            out.spaceUuid.updatedAtMs = 0
            out.parentUuid.updatedAtMs = 0
            out.rank.updatedAtMs = 0
            out.title.updatedAtMs = created
            out.url.updatedAtMs = created
            out.secondaryURL.updatedAtMs = created
            out.secondaryTitle.updatedAtMs = created
            return out
        }

        // R-exec-16: created_at_ms/source are non-LWW fields that BookmarkFieldPatch cannot land. Baselines
        // advance even when only these fields merge and applied=0. If outbound projection keeps local values,
        // devices endlessly alternate projected-versus-reconciled and server-versus-reconciled differences
        // (Mac A/B, 2026-09-14: two 176-byte bookmark commits per minute). Merge with the baseline during
        // projection instead, matching merge output without local writes.
        out.createdAtMs = mergedCreatedAtMs(out.createdAtMs, baseline.createdAtMs)
        // source is a write-once origin tag (§2.1). Preserve a nonzero baseline value rather than overriding
        // it from the local row. Like created_at_ms, its non-LWW merge cannot update the local column through
        // this patch and would otherwise cause the same resend loop.
        if baseline.source != 0 { out.source = baseline.source }

        // Never republish descendant space_uuid (R-M3-3-18); copy the baseline. Moving a folder retags all
        // descendants locally, and publishing that diagnostic change would cause needless commits that could
        // overwrite concurrent remote sorting.
        if !out.parentUuid.stringValue.isEmpty { out.spaceUuid = baseline.spaceUuid }

        let locationStamp = locationValue(out) == locationValue(baseline)
            ? Self.locationStamp(of: baseline) : now
        out.spaceUuid.updatedAtMs = locationStamp
        out.parentUuid.updatedAtMs = locationStamp
        out.rank.updatedAtMs = restamped(out.rank, baseline.rank, now)
        out.title.updatedAtMs = restamped(out.title, baseline.title, contentStamp)
        out.url.updatedAtMs = restamped(out.url, baseline.url, contentStamp)
        out.secondaryURL.updatedAtMs = restamped(out.secondaryURL, baseline.secondaryURL,
                                                 contentStamp)
        out.secondaryTitle.updatedAtMs = restamped(out.secondaryTitle, baseline.secondaryTitle,
                                                   contentStamp)
        return out
    }

    // MARK: - Merge (§4.3)

    /// Symmetric field LWW with position coherence: merge location by LWW; if both locations agree, merge rank
    /// by LWW, otherwise take rank from the location-winning entity. Rank only makes sense in its original
    /// location. Applying this only for a remote winner fails when local location wins but remote rank has a
    /// newer stamp, producing divergent results.
    ///
    /// Start from remote, preserving unknownFields, including reserved fields 12–15 written by newer clients.
    static func merge(local: Phi_PhiBookmarkEntity,
                      remote: Phi_PhiBookmarkEntity) -> Phi_PhiBookmarkEntity {
        var merged = remote
        merged.bookmarkUuid = local.bookmarkUuid.isEmpty ? remote.bookmarkUuid : local.bookmarkUuid

        let localBallot = locationBallot(local)
        let remoteBallot = locationBallot(remote)
        let localWins = SyncableSettings.lwwWinner(localBallot, remoteBallot) == localBallot
        let winner = localWins ? local : remote
        merged.spaceUuid = winner.spaceUuid
        merged.parentUuid = winner.parentUuid
        // §4.3: stamp both members equally when sending the entity.
        let stamp = locationStamp(of: winner)
        merged.spaceUuid.updatedAtMs = stamp
        merged.parentUuid.updatedAtMs = stamp
        merged.rank = localBallot.stringValue == remoteBallot.stringValue
            ? SyncableSettings.lwwWinner(local.rank, remote.rank)
            : winner.rank

        // Invariant, not LWW: rows cannot change between bookmark and folder. refuses rejects isFolderMismatch
        // (§4.6), so both accepted sides agree and remote's value is correct. Merging this disagreement would
        // wrongly legalize an invalid payload.
        merged.isFolder = remote.isFolder

        merged.title = SyncableSettings.lwwWinner(local.title, remote.title)
        merged.url = SyncableSettings.lwwWinner(local.url, remote.url)
        merged.secondaryURL = SyncableSettings.lwwWinner(local.secondaryURL, remote.secondaryURL)
        merged.secondaryTitle = SyncableSettings.lwwWinner(local.secondaryTitle,
                                                           remote.secondaryTitle)
        // Not LWW: prefer nonzero; if both are nonzero and differ, choose the smaller value.
        merged.source = mergedSource(local.source, remote.source)
        // Not LWW: preserve the earliest creation time.
        merged.createdAtMs = mergedCreatedAtMs(local.createdAtMs, remote.createdAtMs)
        return merged
    }

    // MARK: - Refusal (§4.6)

    /// Reject structurally invalid payloads; nil accepts. Validate rank at the decoding boundary: rankBetween
    /// preconditions trap even in release, and untrusted invalid ranks can poison an entire sibling folder.
    ///
    /// Reject is_folder mismatch against the landed baseline rather than merging; rows cannot change kind.
    /// Landing also checks the actual local row's dataType, unavailable here. Cycle detection requires the
    /// full working set and belongs to plan.
    static func refuses(_ entity: Phi_PhiBookmarkEntity,
                        baseline: Phi_PhiBookmarkEntity?) -> OwnedItemRefusal? {
        let uuid = entity.bookmarkUuid
        guard isAccountUuid(uuid) else { return .invalidUuid }
        guard SyncableSpaces.isLegalRank(entity.rank.stringValue) else { return .illegalRank }
        if entity.parentUuid.stringValue == uuid { return .selfReference }
        if !entity.isFolder, URL(string: entity.url.stringValue) == nil { return .invalidURL }
        if let baseline, baseline.isFolder != entity.isFolder { return .isFolderMismatch }
        return nil
    }

    // MARK: - Landing projection (§4.10)

    /// Convert wire rank to dense local index: sort siblings under one parent by rank, then identity UUID, and
    /// return guid → index. Do not filter siblings or excluded rows' stale indices can collide with new ones.
    /// Unpublished rows without rank come first, matching assignRanks' complement rule.
    static func rankToIndex(siblings: [PhiLocalBookmark], ranks: [String: String]) -> [String: Int] {
        let ordered = siblings.sorted { left, right in
            let leftRank = left.syncId.flatMap { ranks[$0] } ?? ""
            let rightRank = right.syncId.flatMap { ranks[$0] } ?? ""
            if leftRank != rightRank { return leftRank < rightRank }
            return (left.syncId ?? left.guid) < (right.syncId ?? right.guid)
        }
        var out: [String: Int] = [:]
        for (index, row) in ordered.enumerated() { out[row.guid] = index }
        return out
    }

    // MARK: - Private helpers

    /// Location value: roots use (space_uuid, empty parent); descendants use (empty Space, parent_uuid).
    /// Descendant space_uuid is excluded.
    private static func locationValue(_ entity: Phi_PhiBookmarkEntity) -> (String, String) {
        let parent = entity.parentUuid.stringValue
        return parent.isEmpty ? (entity.spaceUuid.stringValue, "") : ("", parent)
    }

    /// Encode the whole location group as a ballot for SyncableSettings.lwwWinner (R4 single implementation),
    /// keeping symmetric lexicographic serialized-byte ties. Prefix s/p distinguishes a Space X root from a
    /// child of parent X; otherwise equal ballots would devolve into asymmetric left-wins behavior.
    private static func locationBallot(_ entity: Phi_PhiBookmarkEntity) -> Phi_PhiSettingValue {
        let value = locationValue(entity)
        var ballot = string(value.1.isEmpty ? "s\u{0}" + value.0 : "p\u{0}" + value.1)
        ballot.updatedAtMs = locationStamp(of: entity)
        return ballot
    }

    /// Keep the baseline timestamp when field signatures match; otherwise stamp the edit. Signature means
    /// bytes with updatedAtMs zeroed (R4 single implementation).
    ///
    /// AM-1: a changed field's stamp is `max(editWallMs, baselineStamp + 1)`, never the bare edit column. A
    /// device whose clock runs behind would otherwise overwrite a value it merged from a peer with a SMALLER
    /// stamp, and the causally later edit would lose — the failure C2 exists to remove. For rank, whose
    /// `editWallMs` is already the round's hybrid stamp, the bump is a no-op.
    private static func restamped(_ value: Phi_PhiSettingValue,
                                  _ baseline: Phi_PhiSettingValue,
                                  _ editWallMs: Int64) -> Int64 {
        SyncableSettings.signature(of: value) == SyncableSettings.signature(of: baseline)
            ? baseline.updatedAtMs
            : PhiHybridClock.editStamp(editWallMs: editWallMs,
                                       overwrittenStampMs: baseline.updatedAtMs)
    }

    private static func mergedSource(_ left: Int32, _ right: Int32) -> Int32 {
        if left == 0 { return right }
        if right == 0 { return left }
        return min(left, right)
    }

    /// Merge created_at_ms by preferring nonzero, then the earlier nonzero value. Share this helper between
    /// merge and stamp (R4 / R-exec-16): differing projection and merge rules would alternate X/Y forever,
    /// republishing from both devices each round.
    private static func mergedCreatedAtMs(_ left: Int64, _ right: Int64) -> Int64 {
        [left, right].filter { $0 > 0 }.min() ?? 0
    }

    /// Expected account identity shape. Deliberately avoid RFC-4122 validation: the guard rejects accidental
    /// device-local GUIDs (uppercase, reminted by cloning, §3.1), not alternative peer UUID generators. Strict
    /// validation would reject otherwise valid peer entities.
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

    private static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }
}

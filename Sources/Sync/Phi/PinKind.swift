// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import CryptoKit
import Foundation

// Pinned-tab adapter: encoding, field LWW rules, owner resolution, and timestamps.
// Differences from bookmarks follow from identity being the (lineage, owner) pair (R-M3-3-15):
// - Pins have no location (§4.3). The owner is immutable identity, so there is no location group; rank is an
// ordinary LWW field without bookmark coherence rules.
// - Changing owners emits a tombstone under the old tag and a create under the new tag (§7.2), so PinApplyOp
// has no rebind.
// - Pins never use §6 adoption (§6.7). Initial sync unions both sets without content matching, pairing, or
// deduplication; SyncableOwnedItems.adopt therefore accepts only Phi_PhiBookmarkEntity.
// - Multiple active rows may share a lineage and owner when mergeCandidates retains distinct signatures. They
// are separate visible pins, and normalizeVariants(locals:) remints their identities.

enum PinKind: OwnedItemKind {
    typealias Entity = Phi_PhiPinTabEntity
    typealias Local = PhiLocalPin

    static var tagPrefix: String { PhiSyncEntity.pinTagPrefix }
    static var entityName: String { PhiSyncEntity.pinEntityName }

    // MARK: - Lineage normalization

    /// Convert local pinLineageId (uppercase UUID().uuidString) to wire pin_uuid.
    /// This helper serves client-tag construction (§2.5), index seeding (§5.1), and landing matches (§3.2).
    /// PhiSyncEntity.pinClientTag(_:ownerKey:) only concatenates; callers must normalize before constructing
    /// tags. Putting normalization there would leave the other two paths unguarded. A missed normalization
    /// makes hashes differ from the wire and causes §2.5 validation to reject every pin as a forged payload,
    /// disabling the entire pin channel (§3.2).
    /// Neither direction writes back to the local row; its uppercase value remains intact.
    static func lineageKey(_ lineageId: String) -> String { lineageId.lowercased() }

    // MARK: - Identity and envelope

    /// Wire identity is <pin_uuid>:<ownerKey>, exactly the client tag without its prefix.
    /// Do not call lineageKey here: account pin_uuid is already normalized, and refuses rejects unnormalized
    /// input as invalidUuid. Lowercasing incoming payloads would alias an uppercase payload with a valid
    /// entity, letting plan harvest the wrong entityId/version into its cursor and submit another server
    /// entity's tuple.
    static func identity(of entity: Phi_PhiPinTabEntity) -> String {
        let lineage = entity.pinUuid
        // Empty lineage yields empty identity, rejected by plan's first check for empty uuid.
        guard !lineage.isEmpty else { return "" }
        return lineage + ":" + ownerKey(of: entity)
    }

    /// The local row's account identity is <lineageKey>:<ownerKey>.
    /// Return nil for dormant rows and empty lineage. Dormant rows are local scope-migration backups, excluded
    /// by allPins() and again here from snapshots and diffs. A lineage with only dormant copies therefore
    /// appears locally absent and emits a tombstone.
    /// An unresolved owner still yields an identity with a NUL-prefixed placeholder suffix that cannot be an
    /// account uuid. snapshot increments excluded_unmapped_owner only when identity is non-nil and
    /// eligibilityOwner is nil. Returning nil would hide the entire §4.2 item 1 exclusion class and its only
    /// operational signal of a missing Space mapping.
    /// Two invariants prevent the placeholder reaching the wire:
    /// 1. It appears only for rows whose eligibilityOwner is nil under the same resolver and scope; it is not
    /// a reusable sentinel.
    /// 2. Never derive client tags, cursor keys, wire bytes, or log fields directly from identity(of local:).
    /// Use snapshot(...).entities.keys or table.cursors, both gated on eligibilityOwner != nil. The guards
    /// exclude ineligible candidates, and identityByLocalId also admits only eligible rows. Likewise, refresh
    /// cursor.ownerUuid each round through eligibilityOwner (A12 / §3.5), never by splitting this identity.
    static func identity(of local: PhiLocalPin, resolve: OwnerResolver,
                         scope: PinnedTabScope?) -> String? {
        guard !local.isDormant else { return nil }
        let lineage = lineageKey(local.lineageId)
        guard !lineage.isEmpty else { return nil }
        let owner = eligibilityOwner(of: local, resolve: resolve, scope: scope)
        return lineage + ":" + (owner ?? unresolvedOwnerKey)
    }

    static func envelope(_ entity: Phi_PhiPinTabEntity) -> Phi_PhiEntity {
        var out = Phi_PhiEntity()
        out.pinTab = entity
        return out
    }

    static func entity(from envelope: Phi_PhiEntity) -> Phi_PhiPinTabEntity? {
        guard case .pinTab(let payload)? = envelope.kind else { return nil }
        return payload
    }

    /// Pins are flat: parentId is always nil. Snapshot ancestor checks examine only the pin itself, and plan's
    /// topological sort has no dependencies.
    static func localEdge(of local: PhiLocalPin) -> (id: String, parentId: String?) {
        (id: local.guid, parentId: nil)
    }

    // MARK: - Ownership (§7.2)

    /// Derive the local row's owner using §7.2. nil means its Space/profile is unmapped: skip the whole row
    /// this round and increment excluded_unmapped_owner (§4.2 item 1).
    /// Check spaceId before profileId, not just either non-nil field: Space-scoped rows have both (see
    /// PhiLocalPin.spaceId), and pinnedTab(_:belongsTo:) guarantees exactly one owner.
    /// Never fall back to app on resolution failure: a Space pin would become account-wide and appear in every
    /// remote Space.
    /// Ignore scope here. §7.3 compares account and local scopes and skips the entire publishing phase on
    /// mismatch. allPins() guarantees rows in the current scope, encoded by their shape. Overriding that shape
    /// with scope during incomplete migration could publish Space-shaped rows as App entities.
    /// This is the single implementation for §4.2 eligibility and Task 7 ownerUuid preprocessing (A12 / §3.5).
    static func eligibilityOwner(of local: PhiLocalPin, resolve: OwnerResolver,
                                 scope: PinnedTabScope?) -> String? {
        switch owner(of: local, resolve: resolve) {
        case .space(let uuid), .profile(let uuid): return uuid
        case .app: return appOwnerKey
        case nil: return nil
        }
    }

    /// The single owner reference must resolve before landing.
    /// App scope returns literal app, following the same path as Space/Profile. The engine's OwnerResolver
    /// maps app to itself (see Task 5b / Task 6 constructors), so plan resolves it outside this module and
    /// lands normally. tombstones needs no unmapped-owner exception, preserving §4.7's protection against
    /// deleting a Space's bookmarks during transient mapping loss.
    static func ownerUuids(of entity: Phi_PhiPinTabEntity) -> [String] {
        [ownerKey(of: entity)]
    }

    // MARK: - Outbound projection and timestamps (§4.2)

    /// Project a local row to a wire entity without stamping or assigning rank.
    /// Ignore parentIdentity because pins have no parent. An unresolved owner returns nil, skipping the whole
    /// row this round.
    static func project(_ local: PhiLocalPin, resolve: OwnerResolver,
                        scope: PinnedTabScope?, parentIdentity: String?) -> Phi_PhiPinTabEntity? {
        guard let owner = owner(of: local, resolve: resolve) else { return nil }

        var entity = Phi_PhiPinTabEntity()
        entity.pinUuid = lineageKey(local.lineageId)
        switch owner {
        case .space(let uuid): entity.spaceUuid = uuid
        case .profile(let uuid): entity.profileUuid = uuid
        // App scope leaves the oneof unset (§2.4: absence is one of the three values).
        case .app: break
        }
        entity.rank = string("")
        entity.title = string(local.title)
        entity.url = string(local.url.absoluteString)
        entity.splitPartnerUuid = string(local.splitPartnerLineageId.map(lineageKey) ?? "")
        entity.source = Int32(truncatingIfNeeded: local.source)
        entity.createdAtMs = milliseconds(local.createdDate)
        return entity
    }

    static func rank(of entity: Phi_PhiPinTabEntity) -> String { entity.rank.stringValue }

    /// Return the rank timestamp, not zero.
    /// Pins have no location, but §5.6 L1 (A9) requires the entity's location timestamp to be strictly later
    /// than deleteDecidedAtMs. Zero would make that condition always false and prevent A9 from canceling pin
    /// deletion after a remote move out of a deleted scope. Rank is the pin's sole position dimension, so its
    /// timestamp records that change.
    static func locationStamp(of entity: Phi_PhiPinTabEntity) -> Int64 {
        entity.rank.updatedAtMs
    }

    /// Value bytes of the three content fields with timestamps zeroed, like SyncableSettings.signature(of:).
    /// Exclude rank because move carries it through PinApplyOp.move(guid:index:); including it would add an
    /// empty field patch for every reorder. Include split_partner_uuid, carried by
    /// PinFieldPatch.splitPartnerLineageId, so a split-link-only change produces a step and keeps both
    /// devices' pairs consistent.
    static func contentSignature(of entity: Phi_PhiPinTabEntity) -> Data {
        var out = Data()
        for value in [entity.title, entity.url, entity.splitPartnerUuid] {
            out.append(SyncableSettings.signature(of: value))
            out.append(0)
        }
        return out
    }

    /// Stamp per §4.2 items 4/5: rank has its own timestamp; content fields form the other group.
    /// Without a baseline (§4.2 item 5), stamp rank with 0 so derived local order cannot beat a real remote
    /// action. Stamp title/url with contentUpdatedDate ?? createdDate, and every other field with now (A13).
    /// Stamping old untouched content with now could overwrite last week's remote rename.
    /// split_partner_uuid belongs to the other fields and gets now: §4.2 item 5 names only
    /// title/url/secondary_* as content. A split operation does not change contentUpdatedDate, and an old
    /// timestamp could lose a newly created link to a newer-stamped empty value. It remains in
    /// contentSignature because deciding whether a patch is needed is independent of timestamp choice.
    /// Preserve partially landed split links (§7.4): if the local partner has not landed and its link is nil
    /// while the baseline has a lineage, copy the baseline. Sending an empty string would break an intact
    /// remote pair merely because this device received it.
    static func stamp(_ projected: Phi_PhiPinTabEntity, baseline: Phi_PhiPinTabEntity?,
                      local: PhiLocalPin, rank: String, now: Int64) -> Phi_PhiPinTabEntity {
        var out = projected
        out.rank = string(rank)
        let contentStamp = milliseconds(local.contentUpdatedDate ?? local.createdDate)

        if out.splitPartnerUuid.stringValue.isEmpty,
           let baseline, !baseline.splitPartnerUuid.stringValue.isEmpty {
            out.splitPartnerUuid = baseline.splitPartnerUuid
        }

        guard let baseline else {
            out.rank.updatedAtMs = 0
            out.title.updatedAtMs = contentStamp
            out.url.updatedAtMs = contentStamp
            out.splitPartnerUuid.updatedAtMs = now
            return out
        }
        // R-exec-16, as in BookmarkKind.stamp: created_at_ms and source do not use LWW, while PinFieldPatch
        // writes only three content fields. A created_at_ms-only merge can emit no local ops while advancing
        // both baselines. Merge into the projection first to prevent devices resending the same pin forever.
        out.createdAtMs = mergedCreatedAtMs(out.createdAtMs, baseline.createdAtMs)
        // source is write-once (§2.1): retain a nonzero baseline value instead of overwriting it from the
        // local row.
        if baseline.source != 0 { out.source = baseline.source }
        out.rank.updatedAtMs = restamped(out.rank, baseline.rank, now)
        out.title.updatedAtMs = restamped(out.title, baseline.title, now)
        out.url.updatedAtMs = restamped(out.url, baseline.url, now)
        out.splitPartnerUuid.updatedAtMs = restamped(out.splitPartnerUuid,
                                                     baseline.splitPartnerUuid, now)
        return out
    }

    // MARK: - Merge (§2.4)

    /// Merge fields with LWW, including rank as an ordinary field. Pins have no location group, so bookmark
    /// coherence rules cannot apply.
    /// Leave owner untouched: it is immutable identity (§2.4 / R-M3-3-15), and same-identity entities must
    /// share it. §2.5 tag validation treats a mismatched owner as forged payload, not a rebind, so inheriting
    /// remote's owner is correct.
    /// Start from remote to preserve unknownFields. A fresh Phi_PhiPinTabEntity would erase newer clients'
    /// reserved fields 10–13 every round (Proto/README.md).
    static func merge(local: Phi_PhiPinTabEntity,
                      remote: Phi_PhiPinTabEntity) -> Phi_PhiPinTabEntity {
        var merged = remote
        merged.pinUuid = local.pinUuid.isEmpty ? remote.pinUuid : local.pinUuid
        merged.rank = SyncableSettings.lwwWinner(local.rank, remote.rank)
        merged.title = SyncableSettings.lwwWinner(local.title, remote.title)
        merged.url = SyncableSettings.lwwWinner(local.url, remote.url)
        merged.splitPartnerUuid = SyncableSettings.lwwWinner(local.splitPartnerUuid,
                                                             remote.splitPartnerUuid)
        // Not LWW: nonzero wins; if both are nonzero and differ, choose the smaller value, as for bookmarks.
        merged.source = mergedSource(local.source, remote.source)
        // Not LWW: retain the earliest creation time.
        merged.createdAtMs = mergedCreatedAtMs(local.createdAtMs, remote.createdAtMs)
        return merged
    }

    // MARK: - Refusal (§4.6)

    /// Pins use the two §4.6 checks marked for both kinds: invalid pin_uuid and invalid rank.
    /// Validate rank at the decoding boundary because rankBetween traps via precondition even in release
    /// builds and remote bytes are untrusted.
    /// pin_uuid must already be normalized. Local UUID().uuidString is uppercase and lineageKey handles
    /// normalization (§3.2); accepting unnormalized remote lineage would create two account identities for one
    /// pin.
    /// baseline is unused: pins have no is_folder equivalent, and §2.5 tag validation already rejects owner
    /// disagreement. Keep the parameter for a single §4.6 interface.
    /// Also reject urls that cannot form URL, for the same reason as BookmarkKind.refuses: PhiLocalPin.url is
    /// nonoptional, so landing cannot create or update such a row. §4.6 labels this check for bookmarks
    /// because its wording mentions is_folder, but the structural requirement also applies to pins (see ledger
    /// erratum). Refusal increments refused, writes no cursor, and reevaluates each round so a corrected
    /// remote version can land; silent dropping loses accounting and parking could last forever.
    /// Owner oneof mismatching account scope is neither refusal nor discard (§4.6). plan's scopeMismatch parks
    /// it until scopes converge (§7.3).
    static func refuses(_ entity: Phi_PhiPinTabEntity,
                        baseline: Phi_PhiPinTabEntity?) -> OwnedItemRefusal? {
        guard isNormalizedLineage(entity.pinUuid) else { return .invalidUuid }
        guard SyncableSpaces.isLegalRank(entity.rank.stringValue) else { return .illegalRank }
        if URL(string: entity.url.stringValue) == nil { return .invalidURL }
        return nil
    }

    // MARK: - Variant identity reminting (§7.2 / A11)

    /// For active rows sharing (lineage, ownerKey), collapse exact synced-field duplicates, then remint
    /// pinLineageId for every survivor except the smallest index, breaking ties by lexicographic guid.
    /// Separate two collision types (R-exec-12 / D-A2):
    /// - Different signatures are real variants: mergeCandidates deliberately retains them as distinct visible
    /// pins. Each needs its own identity; otherwise a second row can neither sync nor be deleted remotely
    /// while counters still look healthy.
    /// - Equal signatures are physical copies caused by replay or a landing race. On Mac B, 2026-09-14, the
    /// round-start projection preceded scope migration, so landing recreated a migrated row. Reminting would
    /// make a transient collision a permanent account duplicate, with no mechanism to merge the lineages
    /// again. Keep ordinal 0 and delete the rest, matching mergeCandidates.
    /// Use the same synced fields as mergeCandidates (§7.1 / R-M3-3-16): title, url, splitPartnerLineageId.
    /// Divergent signatures would make migration and sync disagree about pin identity.
    /// Return a PinApplyBatch for the same transaction as that round's landing. Do not write through the
    /// read-only push pre-pass (§4.2 item 2). Reminting is irreversible; a crash after reminting but before
    /// publication cannot restore the old lineage.
    /// Group by local owner id (spaceId ?? profileId ?? app), without a resolver. Within each owner kind,
    /// local-id/account-uuid mappings are one-to-one. Precondition: locals comes from allPins() and belongs to
    /// one scope kind; mixed scopes break that equivalence. Exclude dormant migration backups to keep them
    /// linked to their active rows.
    /// Both the new lineage (mintedLineage(_:ordinal:)) and retained row are deterministic. Collapse and
    /// remint share (index, guid) order, so devices that ran the same deterministic migration retain/delete
    /// the same rows and assign identical ordinals.
    static func normalizeVariants(locals: [PhiLocalPin]) -> PinApplyBatch {
        var groups: [String: [PhiLocalPin]] = [:]
        for local in locals where !local.isDormant {
            let key = lineageKey(local.lineageId) + "\u{0}" + localOwnerKey(local)
            groups[key, default: []].append(local)
        }
        var ops: [PinApplyOp] = []
        // Traverse groups in a fixed order so the same rows produce the same op sequence.
        for key in groups.keys.sorted() {
            let members = (groups[key] ?? []).sorted {
                $0.index == $1.index ? $0.guid < $1.guid : $0.index < $1.index
            }
            // 1. Collapse exact duplicates, retaining the first row per signature. Do this before assigning
            // ordinals: counting identical physical copies would irreversibly create a pin the user never had.
            var survivors: [PhiLocalPin] = []
            var seen: Set<PinVariantSignature> = []
            for row in members {
                guard seen.insert(variantSignature(of: row)).inserted else {
                    ops.append(.delete(guid: row.guid))
                    continue
                }
                survivors.append(row)
            }
            // 2. Start reminting at ordinal 1. Ordinal 0 is the smallest-index survivor, retains its lineage,
            // and emits no op.
            for (ordinal, row) in survivors.enumerated() where ordinal > 0 {
                ops.append(.relineage(guid: row.guid,
                                      newLineageId: mintedLineage(lineageKey(row.lineageId),
                                                                  ordinal: ordinal)))
            }
        }
        return PinApplyBatch(unordered: ops)
    }

    /// Pin equivalence uses only synced fields.
    /// Match LocalStore's PinnedTabVariantSignature (§7.1 / R-M3-3-16): title, url, and split partner. The
    /// local structure also includes partner content, unavailable here because PhiLocalPin references a
    /// partner lineage, not a row. The partner's identity publishes its content changes separately. Copies
    /// whose partner content changed without a lineage change remain the same pin, as intended.
    /// Exclude index: physical copies occupy different positions, so including it would prevent all
    /// collapsing. Also exclude per-copy/per-device guid, source, and both dates.
    private struct PinVariantSignature: Hashable {
        let title: String
        let url: String
        let splitPartnerLineage: String?
    }

    private static func variantSignature(of local: PhiLocalPin) -> PinVariantSignature {
        PinVariantSignature(title: local.title,
                            url: local.url.absoluteString,
                            // The local partner value may be uppercase (legacy guid fallback, P11); normalize
                            // before comparison.
                            splitPartnerLineage: local.splitPartnerLineageId.map(lineageKey))
    }

    // MARK: - Private

    /// Literal App-scope owner in the third client-tag component (§2.4 / §2.5).
    private static let appOwnerKey = "app"

    /// Placeholder suffix for identity(of local:) when owner resolution fails. Its leading NUL cannot occur in
    /// account uuids, keeping it distinct from every real identity; see identity(of local:).
    private static let unresolvedOwnerKey = "\u{0}unresolved-owner"

    private enum PinOwner {
        case space(String)
        case profile(String)
        case app
    }

    private static func owner(of local: PhiLocalPin, resolve: OwnerResolver) -> PinOwner? {
        if let spaceId = local.spaceId {
            guard let uuid = resolve.syncUuid(spaceId) else { return nil }
            return .space(uuid)
        }
        if let profileId = local.profileId {
            guard let uuid = resolve.globalUuid(profileId) else { return nil }
            return .profile(uuid)
        }
        return .app
    }

    /// Wire ownerKey: space_uuid, profile_uuid, or literal app when the oneof is absent.
    private static func ownerKey(of entity: Phi_PhiPinTabEntity) -> String {
        switch entity.owner {
        case .spaceUuid(let uuid): return uuid
        case .profileUuid(let uuid): return uuid
        case nil: return appOwnerKey
        }
    }

    /// Local owner id, used by normalizeVariants for grouping and by
    /// PhiPinnedTabLocalAccess.isKnownLocalPin(_:ownerKey:) as half the identity.
    /// Use the same precedence as owner(of:resolve:): spaceId, then profileId, otherwise App, without crossing
    /// the mapping table. Divergence would make account and local lookups disagree about whether a row exists.
    /// This uses a different namespace from identity(of:resolve:scope:)'s account-uuid suffix. Direct
    /// comparison is invalid; use OwnerResolver's reverse lookup.
    static func localOwnerKey(_ local: PhiLocalPin) -> String {
        local.spaceId ?? local.profileId ?? appOwnerKey
    }

    /// Derive variant lineage from the first 16 SHA-1 bytes of (original lineage, ordinal), formatted as a
    /// lowercase 8-4-4-4-12 uuid-shaped string.
    /// It must be deterministic across devices (A11). migratePinnedTabs assigns deterministic lineage and
    /// index (§3.2), yielding identical groups and order. Random UUIDs would make each device publish and
    /// receive distinct variants; §6.7 excludes pin adoption, so both devices would gain one permanent
    /// duplicate per variant.
    /// Deliberately omit ownerKey: only local owner ids are available here, and Space ids are device-specific
    /// (LocalStore+Space.swift:69). Including them would destroy determinism; account owner keys need a
    /// resolver unavailable to normalizeVariants(locals:). Identity is the (lineage, owner) pair, so identical
    /// derived lineage under different owners is unambiguous and matches Profile-to-Space fan-out. Ordinals
    /// remain distinct within an owner.
    /// The prefix separates this derivation from other uuid-hashing schemes. This is uuid-shaped, not RFC-4122
    /// v4 with version bits; the local column does not validate shape, and the wire requires only
    /// normalization.
    private static func mintedLineage(_ lineage: String, ordinal: Int) -> String {
        let seed = "phi-pin-variant|" + lineage + "|" + String(ordinal)
        let digest = Array(Insecure.SHA1.hash(data: Data(seed.utf8))).prefix(16)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        var out = ""
        for (offset, character) in hex.enumerated() {
            if offset == 8 || offset == 12 || offset == 16 || offset == 20 { out.append("-") }
            out.append(character)
        }
        return out
    }

    /// Check normalized lineage, not RFC-4122 validity. Other valid generators and the five guid fallbacks in
    /// LocalStore+PinnedTabScope.swift / LocalStore+PinnedTabTransfer.swift may produce non-uuid shapes. Match
    /// BookmarkKind.isAccountUuid.
    /// Reject colons: lineage + ':' + ownerKey must be reversible. Pairs (a:b, c) and (a, b:c) would otherwise
    /// share an identity, allowing forged payloads to harvest another entity's entityId/version and add a
    /// client-tag component. Reject NUL as well because unresolved-owner placeholders and grouping keys use
    /// it.
    private static func isNormalizedLineage(_ lineage: String) -> Bool {
        !lineage.isEmpty
            && !lineage.contains(where: { $0.isUppercase })
            && !lineage.contains(where: { $0.isWhitespace || $0.isNewline })
            && !lineage.contains(":")
            && !lineage.unicodeScalars.contains("\u{0}")
    }

    /// Reuse the baseline timestamp when the field signatures match; otherwise stamp now.
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

    /// Merge created_at_ms: nonzero wins; if both are nonzero, choose the earlier time. merge and stamp share
    /// this implementation (R4 / R-exec-16); see BookmarkKind's same-named function.
    private static func mergedCreatedAtMs(_ left: Int64, _ right: Int64) -> Int64 {
        [left, right].filter { $0 > 0 }.min() ?? 0
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

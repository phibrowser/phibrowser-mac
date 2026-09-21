// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import SwiftProtobuf

// Owned-item (bookmark/pin) snapshot, diff, plan, adoption, and §4.3 location merge.
// This file contains only pure functions, like SyncableSpaces.swift:19–22. The
// engine owns persistence; snapshot writes nothing. No actor hops, LocalStore,
// or UserDefaults are involved, so tests can run without SwiftData.
// Reuse SyncableSpaces' rankAlphabet, rankBetween, longestIncreasingKeptSet,
// assignRanks, and isLegalRank primitives (R4, single implementation). Duplicating
// them would let account-wide ordering rules drift.

/// Identity translation and owner eligibility computed once by the engine at
/// round start. Pure functions must not access PhiSpaceSyncTable or mapping stores.
struct OwnerResolver {
    /// Local spaceId to account-wide syncUuid.
    var syncUuid: (String) -> String?
    /// syncUuid to local spaceId.
    var localSpaceId: (String) -> String?
    /// Conjunction from §4.2 rule 1: present in currentSpaces, mapped to syncUuid,
    /// and a Space cursor with neither hidden nor purgedAtMs. Only meaningful for
    /// Space ownership; call it only when localSpaceId resolves, preserving Profile/App pins.
    var isEligibleSpace: (String) -> Bool
    /// Local profileId to account-wide Profile UUID.
    var globalUuid: (String) -> String?
    /// Profile UUID to local profileId.
    var localProfileId: (String) -> String?
    /// Local spaceId to the local profileId the Space is bound to (review A4/A5). A row landed
    /// into a Space belongs to that Space's Profile — never to whichever Profile a sibling row
    /// happens to carry, and never to the default Profile by fallback: a bookmark created under
    /// the wrong Profile has no root to land in, and a pin created under it is invisible to the
    /// Space's windows.
    var localProfileIdForSpace: (String) -> String? = { _ in nil }
}

/// Protocol tuple plus payload. plan needs server-assigned entityId/version
/// for §5.6 L1 harvesting; these belong to PhiRemoteEntity, not the encrypted payload.
struct OwnedItemArrival<Entity> {
    var entity: Entity
    var entityId: String
    var version: Int64
}

/// All round context for plan's sixth parameter, avoiding signature changes
/// for every additional rule.
struct OwnedItemPlanContext {
    /// Adoption pairs: entity identity to stable local row id (bookmark guid or PhiLocalURLRule.id).
    var pairs: [String: String] = [:]
    /// Field-level merges from §6.2 / OwnedItemAdoptionResult.merges, mapping
    /// identity to serialized Phi_PhiEntity envelopes. plan substitutes these for
    /// inbound entities so application uses merged values, not wholesale remote
    /// adoption. Bytes keep this context nongeneric.
    var adoptedMerges: [String: Data] = [:]
    /// OwnedItemAdoptionResult.fieldWrites: identities needing field writes after
    /// claim. Others produce only claim because local content already equals the
    /// merge; an empty update patch would be redundant.
    var adoptedFieldWrites: Set<String> = []
    /// Tombstone identities arriving this round; promote children only when parent death is confirmed.
    var tombstonedIdentities: Set<String> = []
    /// Identity to the current local outbound projection as serialized Phi_PhiEntity,
    /// stamped by the adapter under §4.2 rules 4/5: exactly what snapshot would publish.
    /// §4.3 merges current local and remote entities symmetrically; local is not
    /// reconciled. Using baseline as local omits unpublished edits, letting any
    /// remote field change return stale local values that a grouped bookmarkPatch
    /// silently overwrites. Baseline determines publication differences and stamps,
    /// not application values.
    /// Compute only for identities with baselines. Others use §6.2 adoptedMerges
    /// or initial remote adoption; baseline-free stamping assigns zero location/rank
    /// and contentUpdatedDate to content, which is adoption policy, not the policy
    /// for an existing account row.
    var localProjections: [String: Data] = [:]
    /// Identities removed by a remote folder tombstone this round (A9's third conjunct).
    var deletedSubtree: Set<String> = []
    /// Parent identities resolving to live local rows (A9's second conjunct).
    var liveLocalParents: Set<String> = []
    /// Local/account pin scopes; bookmarks pass nil for both. Two nonnil unequal
    /// values trigger §7.3: no plan steps and all inbound entities parked.
    var localScope: PinnedTabScope? = nil
    var accountScope: PinnedTabScope? = nil
    /// Pre-page-application merge signatures by identity (D30 / §8.4.1), supplied
    /// by the adapter pre-pass (8b-2 ruling 2). plan has projection bytes, not local
    /// rows, so it only copies present entries into preLandingSignatures when
    /// emitting move/update; missing identities remain absent.
    /// Use [String: RuleSignature] exactly (ruling 1): AnyHashable would replace
    /// compile-time grouping with runtime casts that can silently fail (RR12-1).
    /// A third associated type would make OwnedItemPlan generic and affect every
    /// bookmark/pin caller. This file already names pin-specific PinnedTabScope
    /// and the repository has one Swift module, so no new build dependency arises.
    /// Bookmark/pin contexts never populate this table.
    var localSignatures: [String: RuleSignature] = [:]
    /// Scope changed after initial sampling (R-exec-12): both values originally
    /// agreed but no longer match that pair before application. The local projection
    /// is stale, so apply the same §7.3 handling as scope mismatch, even though
    /// this proves stale sampling rather than current local/account disagreement.
    var scopeMovedMidRound = false
    var scopeMismatch: Bool {
        if scopeMovedMidRound { return true }
        guard let localScope, let accountScope else { return false }
        return localScope != accountScope
    }

    // MARK: §8.4.4's four named inputs (R-M3-4a-73, 8b-3)
    // Bookmark/pin contexts leave these empty, making the new branches unreachable.
    // Keep criteria in the kind: signatures and soft deletion are rule-specific
    // and this generic context cannot inspect row flags.

    /// Identities meeting α's first three conditions (row exists, not soft-deleted,
    /// with signature) and pendingLocalEdit=true.
    var pendingLocalEdits: Set<String> = []
    /// Identities meeting α's first three conditions and nonnil, unequal server
    /// and reconciled values, matching publication's pending set.
    var unpublished: Set<String> = []
    /// Identity to partner W identity, only when the three-step lookup finds a
    /// quiescent W. This domain is not limited by α's first three conditions (RR8-1):
    /// β's X is soft-deleted by definition.
    var mergePartners: [String: String] = [:]
    /// Identities whose group has a partner but whose three-step search finds no
    /// quiescent W (RR10-3). Distinguish this from no partner; conflating both
    /// as a missing dictionary key incorrectly falls back to ii/A9 while the partner is active.
    var partnerNotAtRest: Set<String> = []
}

/// Transfer source values captured from their origin (§8.4.4 / RR8-2).
/// Application consumes these values without rereading rows or entities.
/// Add targetSpaceId to the spec declaration because application writes the
/// local SpaceURLRule.spaceId, while targetOwnerUuid is account-wide. The kind
/// performs reverse lookup, keeping LocalStore unaware of account mappings (ruling 3).
struct RuleProjection: Equatable, Sendable {
    var host: String
    var pathPrefix: String?
    var askBeforeRouting: Bool
    /// Content-group timestamp carried by host (§8.2 rule 1).
    var contentUpdatedDate: Date?
    /// Account-wide target identity.
    var targetOwnerUuid: String
    /// Reverse-resolved local Space id for that target; nil skips target transfer.
    var targetSpaceId: String?
    /// Target timestamp.
    var targetUpdatedDate: Date?
    /// Local rank-unit value (8b-4 / ruling 3), read only by §8.4.5's two flag-clearing
    /// paths. They compare three current row units; rank is local sortOrder:Int
    /// but wire lexicographic assignRanks output, which the store cannot convert.
    /// Without it, an in-flight ask edit followed by a pure drag can falsely match,
    /// clear the flag, and let a remote tombstone destroy the rule and drag intent.
    /// Transfer never reads this field because rank is not transferred (§8.4.4
    /// row 3). Entity-derived transferSource leaves it nil; clearing treats nil
    /// as unequal, failing closed (URLRuleKind.clearingProjectionMatches).
    var sortOrder: Int? = nil
}

/// Application phase and sort key (§4.4 / R-M3-4a-93): claim/create/move first,
/// update second, transfer third, delete fourth. Transfer must follow update
/// to compare against W's current per-unit values, and precede deletion of X
/// so edits survive. Do not combine it with update: update reads inbound
/// payloads, while transfer reads X's local projection and compares each unit by LWW.
enum StepKind: Equatable {
    case claim        // Claim: assign account identity to an existing local row (§6.3 step ①)
    case create
    case move         // Change parent, Space, or position
    case update       // Change content fields only
    /// §8.4.4 third-phase transfer moves unpublished user intent to merge partner
    /// to. source is a value (RR8-2): the two branches use different sources,
    /// and application must not guess which branch to read.
    case transfer(source: RuleProjection, to: String)
    case delete
}

struct OwnedItemApplyStep: Equatable {
    var identity: String
    var kind: StepKind
    /// Parent explicitly chosen by the module; empty string means Space root.
    /// nil uses the payload's parent, including root bookmark creates and all
    /// parentless pins. Nonnil is reserved for actual decisions: promotion to
    /// root (§4.4 step 5) or attachment to a parent applying in this round.
    var newParentUuid: String?
    /// M3-4a / R-M3-4a-26: nonnil when this step changes the ownership bucket.
    /// Only kinds with mutable ownership populate it. Bookmarks use newParentUuid
    /// and location; pin owner is immutable in the client tag. Default nil
    /// preserves all bookmark/pin constructors and equality assertions.
    var newOwnerUuid: String? = nil
    var newRank: String?
    /// Serialized Phi_PhiEntity bytes to store as reconciled after application.
    var payload: Data?
}

/// Parked item with the owner UUID it awaits (§4.4 step 4). The engine records
/// it as pendingOwnerUuid to decide next round whether application can retry.
struct ParkedOwnedItem: Equatable {
    var payload: Data
    var pendingOwnerUuid: String?
}

struct OwnedItemPlan {
    var steps: [OwnedItemApplyStep]    // Sorted into §4.4's four phases (R-M3-4a-93)
    var parked: [String: ParkedOwnedItem]
    var refused: Int
    var lifted: Int
    var supersededByDelete: Int
    var cancelledDeletes: Set<String>
    /// Identity to harvested protocol entityId/version, even for discarded entities.
    var harvest: [String: (entityId: String, version: Int64)]
    /// Identities whose local fields won the merge and must republish, matching
    /// OwnedItemAdoptionResult.mustRepublish (§6.2). Normal diff sees no change
    /// after application because local rows equal reconciled bytes. Without explicit
    /// publication, the winning local value never reaches the account despite apparent convergence.
    var mustRepublish: Set<String> = []
    /// Identities producing no steps this round whose tombstones must also park
    /// (RR9-15). The caller records pendingTombstone for the next working set.
    /// Populate on both whole-batch §7.3 scope-mismatch exits and per-identity
    /// §8.4.4 α branches with a nonquiescent W. The normal return must carry
    /// this set; defaulting it empty silently loses deletion after tuple harvesting
    /// and marker advancement, with no redelivery.
    /// This complements parked for live payloads: tombstones carry only tag hashes
    /// (§2.5), so report their identities here.
    var parkedTombstones: Set<String> = []
    /// Only §8.4.4 ii identities (R-M3-4a-61), excluding transfers and parking.
    /// The caller retains the row, clears both baselines and three pending flags,
    /// and records/preserves deletedAtMs for round-end 3b republication. Never add
    /// them to deleted or call noteDeletedRows: the retained disk row and refreshed
    /// projection are prerequisites for 3b.
    var yieldedTombstones: Set<String> = []
    /// New reconciled bytes for identities producing no steps this round. LWW
    /// compares value and stamp: a remote A→B→A can yield A@300 while local
    /// baseline remains A@100. No field patch is needed, but baseline must advance
    /// or delayed B@200 can win and overwrite the newer account A.
    /// This preserves apply-before-baseline (§4.5): by definition no application
    /// is needed; merged and baseline values match, differing only in timestamps.
    var rebaselined: [String: Data] = [:]
    /// Pre-page-application signatures (D30 / §8.4.1 / R-M3-4a-73), copied from
    /// context.localSignatures only when emitting move/update. §8.4.3 step 1's
    /// second pointer pass groups by these old signatures: moved rule Z and
    /// unchanged duplicate X no longer share their current target, exactly the
    /// case needing a pointer (R-M3-4a-74/75). Never reread after application,
    /// use newOwnerUuid (the new target), or freeze once at round start; pre-pass
    /// runs every page (CASE M2-b). Always empty for bookmarks/pins.
    var preLandingSignatures: [String: RuleSignature] = [:]
}

/// §4.6 structural refusal criteria, without refusedAtMs. Recheck each round
/// so corrected remote payloads can recover; remembering refusal on Spaces
/// turned an optimization into permanent exclusion.
enum OwnedItemRefusal: Equatable {
    case illegalRank, cycle, isFolderMismatch, selfReference, invalidUuid, invalidURL
    /// §5.4: normalized host is empty; all three write paths and the bridge discard such rows.
    case emptyHost
    /// §5.4: normalized host is * or *.; both matchers explicitly reject these.
    case degenerateHost
    /// §5.4: host contains slash, or colon without being a bracketed IPv6 literal.
    case malformedHost
}

struct OwnedItemSnapshotResult<Entity> {
    /// Every eligible local row, not only changed rows. The caller compares
    /// serialized entities with reconciled and selects differing identities for publication.
    var entities: [String: Entity]
    /// Rows skipped because owner syncUuid lookup is unmapped.
    var skippedUnmappedOwner: Int
    /// Rows with mapped but ineligible hidden/purged Space owners. Combine this
    /// and unresolved-owner count into excluded_unmapped_owner (§11.2); separate
    /// members let tests assert the two exclusion paths independently.
    var skippedIneligibleOwner: Int
}

/// Tombstone result includes cursor changes, not only identities. §4.7 requires
/// clearing pendingApply, setting pendingDelete/deleteDecidedAtMs, and harvesting
/// entityId/version. Pure functions hold a table value copy, so return updates
/// for the engine to persist.
struct OwnedItemTombstoneResult {
    /// Tombstone identities ordered child-before-parent, reverse topologically (§5.3).
    var identities: [String]
    /// Identity to updated cursor value for the caller's table.
    var cursorUpdates: [String: PhiOwnedItemCursor]
    /// Return deferredDeletions unchanged (default empty, R-M3-4a-84). The engine
    /// subtracts these from deleteCandidates too: an already-pending identity
    /// produces no cursor update but would still pass the existing candidate filter.
    var deferred: Set<String> = []
}

struct OwnedItemAdoptionResult {
    var pairs: [String: String]        // Entity identity to local guid
    var adopted: Int
    var unmatchedFolders: Int
    /// §6.2 field merges as identity-to-envelope bytes. Local content uses
    /// contentUpdatedDate ?? createdDate against remote LWW stamps; location
    /// comes from remote because an unbaselined local position is only derived.
    /// Pass these into context.adoptedMerges.
    var merges: [String: Data] = [:]
    /// Identities with locally winning fields must republish through normal
    /// snapshot/commit selection, or remote values stay stale despite apparent convergence.
    var mustRepublish: Set<String> = []
    /// Identities whose merged content differs from the current row and needs
    /// a local field write. This complements mustRepublish: local wins need
    /// account updates, while remote wins need row updates. Claiming without
    /// writing remote renames leaves old local titles against new reconciled
    /// baselines, causing stale republication and permanent divergence.
    var fieldWrites: Set<String> = []
    /// Matched pairs discarded because projection prevented a merge. Never
    /// fall back to wholesale remote adoption, which can silently erase local
    /// edits during mapping fluctuations. Leave the row unsynced and retry next round.
    var unmergeablePairs: Int = 0
}

#if DEBUG
/// Test-only count of this module's direct rankBetween calls (CASE 4a.8).
/// Exclude assignRanks internals, an unchanged SyncableSpaces algorithm.
/// The probe guards inbound plan paths from passing untrusted ranks into a
/// function with trapping preconditions.
enum RankProbe {
    nonisolated(unsafe) private(set) static var rankBetweenCalls = 0
    static func reset() { rankBetweenCalls = 0 }
    static func note() { rankBetweenCalls += 1 }
}
#endif

/// Thin owned-item adapter for coding, field LWW, ownership, and stamping.
/// The generic module knows this protocol, not bookmarks or pins.
/// Additions to §4.1 expose information only the adapter knows:
/// - localEdge supplies local id/account identity pairs so snapshot can derive
///   in-memory parent identities from locals (§4.2 rule 2).
/// - rank reads baseline rank for assignRanks from generic Entity.
/// - locationStamp exposes §4.3's carrier and A9's first conjunct, retaining
///   the BookmarkKind signature specified by the design.
/// - stamp applies §4.2 rules 4/5 by location/rank/content groups; project
///   remains a pure, unstamped projection.
protocol OwnedItemKind {
    /// Wire entity type, such as Phi_PhiBookmarkEntity or Phi_PhiPinTabEntity.
    associatedtype Entity: SwiftProtobuf.Message & Equatable
    /// Local-row value snapshot, such as PhiLocalBookmark or PhiLocalPin.
    associatedtype Local

    static var tagPrefix: String { get }        // "phi-bookmark:" / "phi-pin:"
    static var entityName: String { get }       // Server plaintext constant

    static func identity(of entity: Entity) -> String
    /// Account identity of a local row; bookmarks use syncId, with nil meaning
    /// no identity minted and no publication this round.
    static func identity(of local: Local, resolve: OwnerResolver, scope: PinnedTabScope?) -> String?

    static func envelope(_ entity: Entity) -> Phi_PhiEntity
    static func entity(from envelope: Phi_PhiEntity) -> Entity?

    /// Project local row to wire entity without timestamps or rank. Unresolved
    /// ownership returns nil and skips the whole row (§4.2 rule 1). parentIdentity
    /// is the parent's account identity; nil attaches directly to the Space root.
    static func project(_ local: Local, resolve: OwnerResolver, scope: PinnedTabScope?,
                        parentIdentity: String?) -> Entity?
    /// Field LWW merge must start from remote to preserve unknown fields (Proto/README.md).
    static func merge(local: Entity, remote: Entity) -> Entity
    /// Structural refusal, or nil to accept. baseline is the already-applied
    /// entity, if any, required by §4.6's is_folder check: a row cannot change
    /// between bookmark and folder. Keep that mismatch in this single refusal
    /// table rather than merging it or adding a separate protocol member.
    static func refuses(_ entity: Entity, baseline: Entity?) -> OwnedItemRefusal?
    /// Ownership references that must resolve before application. Plural because
    /// §4.4 step 4 may need pendingOwnerUuid for any of several references.
    /// Bookmarks return only the binding reference: parent_uuid for descendants,
    /// space_uuid for roots. Descendant space_uuid is diagnostic and ignored
    /// (R-M3-3-18); requiring it would permanently park moved subtrees on new
    /// devices after deletion of their old Space.
    static func ownerUuids(of entity: Entity) -> [String]

    /// Current local owner: containing Space syncUuid for bookmarks, inferred
    /// ownerKey for pins; nil means unmapped. Distinct from ownerUuids, which
    /// lists application prerequisites and names a descendant's parent. Hidden/purged
    /// filtering needs the containing Space; a bookmark UUID cannot resolve as
    /// a Space, so using ownerUuids would let descendants under soft-deleted
    /// Spaces publish for 30 days before purge silently deletes them. This same
    /// value refreshes cursor.ownerUuid each round (A12 / §3.5); keep one implementation.
    static func eligibilityOwner(of local: Local, resolve: OwnerResolver,
                                 scope: PinnedTabScope?) -> String?

    static func localEdge(of local: Local) -> (id: String, parentId: String?)
    static func rank(of entity: Entity) -> String
    static func locationStamp(of entity: Entity) -> Int64
    /// `now` is the round's hybrid-logical stamp; `hlcMax` is the logical time the round started from,
    /// AM-1's floor for a merge unit with no baseline. A changed unit WITH a baseline takes its own
    /// edit-date column, raised one above the baseline's stamp.
    static func stamp(_ projected: Entity, baseline: Entity?, local: Local,
                      rank: String, now: Int64, hlcMax: Int64) -> Entity
    /// Content-value bytes with timestamps zeroed, like SyncableSettings.signature.
    /// Use these to decide field patches; whole-entity comparison would turn
    /// remote restamps into empty updates. Exclude location/rank, carried by move.
    static func contentSignature(of entity: Entity) -> Data

    /// Current target ownership bucket, such as target_space_uuid for rules.
    /// nil means immutable ownership or no single target field, leaving newOwnerUuid
    /// absent. Do not derive this from ownerUuids.first (R-M3-4a-26 / RR-B5):
    /// application-prerequisite references may intentionally exclude an owner.
    /// The generic planner therefore needs a dedicated protocol member.
    static func targetOwnerUuid(of entity: Entity) -> String?

    /// §8.4.4: inbound deletion yields to unpublished user intent for this kind.
    /// True for rules; false for bookmarks/pins in this milestone (§6.1 / §14.1).
    /// Bookmark volume and deletion frequency differ; making every deletion
    /// resurrect across all kinds would create a different data-loss problem.
    static var tombstoneYieldsToLocalEdits: Bool { get }

    /// §8.4.4 transfer source: derive RuleProjection from an entity. α uses X's
    /// local projection; β uses this round's merged entity. Keep extraction in
    /// the kind and pass values (RR8-2); resolver only translates the target
    /// to local Space id. This is a kind query like locationStamp/contentSignature,
    /// not a fifth context input: R-M3-4a-73 / §11 fix that set at four.
    static func transferSource(of entity: Entity, resolve: OwnerResolver) -> RuleProjection?
}

extension OwnedItemKind {
    /// Default nil preserves BookmarkKind/PinKind implementations and behavior.
    static func targetOwnerUuid(of entity: Entity) -> String? { nil }
    /// Default off makes both new branches unreachable for bookmarks/pins (ruling 10).
    static var tombstoneYieldsToLocalEdits: Bool { false }
    /// Default nil for the same compatibility guarantee.
    static func transferSource(of entity: Entity, resolve: OwnerResolver) -> RuleProjection? { nil }
}

/// Owner-reference state for plan step 3. File-scoped because generic functions
/// cannot contain nested types.
private enum OwnerState {
    /// Another entity in this round's working set: a dependency edge.
    case item(String)
    /// Confirmed dead parent: a current tombstone or finalized cursor deletedAtMs.
    case lift
    /// Owner resolved outside the module: eligible Space, mapped Profile, or live local parent row.
    case external
    case unresolved
}

enum SyncableOwnedItems {

    // MARK: - Rank primitive forwarding

    /// Forward to SyncableSpaces.rankBetween through the test probe. This module's
    /// only rank generation is snapshot's assignRanks, which receives this function,
    /// so the probe measures real calls. Inbound plan must never call it: untrusted
    /// remote ranks could trigger release-build precondition traps.
    static func rankBetween(_ a: String?, _ b: String?) -> String {
        #if DEBUG
        RankProbe.note()
        #endif
        return SyncableSpaces.rankBetween(a, b)
    }

    // MARK: - Outbound snapshot (§4.2)

    /// Outbound entities for all eligible local rows, keyed by identity. Pure: no
    /// writes. The engine provides locals with candidate syncIds already assigned
    /// in memory (§4.2 rule 2). Filter ownership here, not at the caller: diffing
    /// must still see excluded rows (§4.7).
    /// Precondition: locals are in sibling order, for bookmarks spaceId/parentGuid/index/guid
    /// per allBookmarks. assignRanks takes this as current local order; another
    /// ordering would needlessly change ranks every round.
    /// `hlcMax` is AM-1's floor for a row with no baseline; 0 means "no floor", which is what a
    /// caller with no engine clock wants.
    static func snapshot<K: OwnedItemKind>(_ kind: K.Type, locals: [K.Local],
                                           table: PhiOwnedItemTable, resolve: OwnerResolver,
                                           scope: PinnedTabScope?, now: Int64, hlcMax: Int64 = 0)
        -> OwnedItemSnapshotResult<K.Entity> {
        var skippedUnmappedOwner = 0
        var skippedIneligibleOwner = 0

        // Pass 1: each row's own sync eligibility (§4.2 rules 1/3). eligibilityOwner
        // identifies its containing Space, not its binding parent. A descendant's
        // parent bookmark UUID would bypass Space eligibility and allow publication
        // under an account-soft-deleted Space.
        var indexByLocalId: [String: Int] = [:]
        var identityOf: [String?] = []
        var selfEligible: [Bool] = []
        for (offset, local) in locals.enumerated() {
            indexByLocalId[K.localEdge(of: local).id] = offset
            guard let identity = K.identity(of: local, resolve: resolve, scope: scope) else {
                identityOf.append(nil)
                selfEligible.append(false)
                continue
            }
            identityOf.append(identity)
            guard let owner = K.eligibilityOwner(of: local, resolve: resolve, scope: scope) else {
                skippedUnmappedOwner += 1
                selfEligible.append(false)
                continue
            }
            if resolve.localSpaceId(owner) != nil, !resolve.isEligibleSpace(owner) {
                skippedIneligibleOwner += 1
                selfEligible.append(false)
                continue
            }
            // §4.2 rule 3 excludes parked, pending-tombstone, and pending-delete cursors.
            // Snapshotting a parked row would restamp local fields with now and update
            // the account through its harvested entityId/version, overwriting remote values.
            if let cursor = table.cursors[identity] {
                guard cursor.pendingApply == nil, !cursor.pendingTombstone,
                      !cursor.pendingDelete else {
                    selfEligible.append(false)
                    continue
                }
            }
            selfEligible.append(true)
        }

        // §4.2 rule 2: every ancestor must be sync-eligible; otherwise skip the row.
        // Do not count this as unmapped ownership. Publishing a child whose parent
        // is parked, tombstoned, or expiring leaves an account entity referencing
        // a parent that should not exist.
        func chainEligible(_ offset: Int) -> Bool {
            guard selfEligible[offset] else { return false }
            var hops = 0
            var parentId = K.localEdge(of: locals[offset]).parentId
            while let id = parentId, hops <= locals.count {
                guard let parentOffset = indexByLocalId[id], selfEligible[parentOffset] else {
                    return false
                }
                parentId = K.localEdge(of: locals[parentOffset]).parentId
                hops += 1
            }
            return true
        }

        // Map local id to account identity for eligible rows only; children may reference only eligible parents.
        var identityByLocalId: [String: String] = [:]
        for (offset, local) in locals.enumerated() where selfEligible[offset] {
            identityByLocalId[K.localEdge(of: local).id] = identityOf[offset]
        }

        var candidates: [(identity: String, local: K.Local, entity: K.Entity, group: String)] = []
        // At most one candidate per identity (R-exec-12 / D-B). Pins derive identity
        // from lineage/owner, so multiple physical rows can collide, unlike bookmark
        // syncId rows. Without deduplication, assignRanks sees a repeated UUID: its
        // second occurrence cannot join the strictly increasing kept set and gets
        // a new rank each round, overwriting the retained rank in the UUID-keyed result.
        // Byte comparison then republishes forever, with keys growing every round
        // (Mac B, 2026-09-14: 25 rounds in a minute, 922–934 bytes).
        // Keep the first row in allPins ownerKey/index/guid order, matching
        // normalizeVariants' survivor. Normally identities are unique and nothing is dropped.
        var claimedIdentities: Set<String> = []
        for (offset, local) in locals.enumerated() {
            guard chainEligible(offset), let identity = identityOf[offset] else { continue }
            guard claimedIdentities.insert(identity).inserted else { continue }
            let parentIdentity = K.localEdge(of: local).parentId.flatMap { identityByLocalId[$0] }
            // Ownership already passed the first scan. A defensive projection failure
            // skips silently without incrementing exclusion counters twice.
            guard let entity = K.project(local, resolve: resolve, scope: scope,
                                         parentIdentity: parentIdentity) else { continue }
            candidates.append((identity, local, entity,
                               K.ownerUuids(of: entity).joined(separator: "\u{0}")))
        }

        // Baselines feed both change detection and rank assignment.
        var baselines: [String: K.Entity] = [:]
        for candidate in candidates {
            guard let bytes = table.cursors[candidate.identity]?.reconciled,
                  let envelope = try? Phi_PhiEntity(serializedBytes: bytes),
                  let entity = K.entity(from: envelope) else { continue }
            baselines[candidate.identity] = entity
        }
        // The rank channel's sole decoding boundary: baseline ranks are remote bytes.
        // Only legal ranks reach rankBetween; invalid ranks become absent and enter
        // assignRanks' complement to receive valid replacements.
        func baselineRank(_ identity: String) -> String? {
            guard let rank = baselines[identity].map(K.rank(of:)),
                  SyncableSpaces.isLegalRank(rank) else { return nil }
            return rank
        }

        // Group by owner: bookmark parent or pin owner. Ranks compare only within a group.
        var groupOrder: [String] = []
        var groups: [String: [Int]] = [:]
        for (offset, candidate) in candidates.enumerated() {
            if groups[candidate.group] == nil { groupOrder.append(candidate.group) }
            groups[candidate.group, default: []].append(offset)
        }
        var assigned: [String: String] = [:]
        for key in groupOrder {
            let members = groups[key] ?? []
            let order = members.map { (uuid: candidates[$0].identity,
                                       rank: baselineRank(candidates[$0].identity)) }
            for (identity, rank) in SyncableSpaces.assignRanks(order: order,
                                                              rankBetween: rankBetween) {
                assigned[identity] = rank
            }
        }

        var entities: [String: K.Entity] = [:]
        for candidate in candidates {
            let rank = assigned[candidate.identity] ?? baselineRank(candidate.identity) ?? "V"
            entities[candidate.identity] = K.stamp(candidate.entity,
                                                   baseline: baselines[candidate.identity],
                                                   local: candidate.local, rank: rank, now: now,
                                                   hlcMax: hlcMax)
        }
        return OwnedItemSnapshotResult(entities: entities,
                                       skippedUnmappedOwner: skippedUnmappedOwner,
                                       skippedIneligibleOwner: skippedIneligibleOwner)
    }

    // MARK: - Diff tombstones (§4.7)

    /// Snapshot diff is the sole bookmark/pin local-deletion source: LocalStore
    /// has no delete hook and publishers report absence. Three criteria prevent
    /// destructive false deletions:
    /// - reconciled must exist, not merely entityId: parked arrivals harvest ids
    ///   before application and must not tombstone newly created remote entities.
    /// - deletedAtMs must be nil to suppress echoes after remote deletion.
    /// - The local row must actually be absent.
    /// Unmapped and ineligible ownership are not absence; those rows exist but
    /// do not publish. Confusing them can delete a whole Space during mapping changes.
    ///
    /// pendingApply is not a fourth criterion (A7). With a baseline it means an
    /// applied row awaits a newer remote edit; local deletion wins, emits a
    /// tombstone, and clears pendingApply in the same update.
    /// pendingClaims exempts identities actually matched this round whose syncId
    /// write failed, such as under an import lock (R-exec-9). They await only
    /// persistence; deleting them would remove an agreed account entity and then
    /// remint the local row as an unrelated create. Never exempt all pendingApply:
    /// unmatchable rows edited/deleted during retry must remain deletable.
    ///
    /// explicitDeletions is the seventh argument and rules' second tombstone
    /// source (R-M3-4a-78). Ordinary owner gates protect followers. A user Space
    /// delete removes SpaceModel in the same transaction while its mapping remains,
    /// making eligibility false and suppressing every rule tombstone. Explicit
    /// user-intent soft deletions bypass only the two owner gates, preserving
    /// the three criteria, pendingClaims exemption, and cursor bookkeeping.
    /// The set must represent deletion decisions, not missing rows (R-M3-4a-85):
    /// retention purge follows remote deletion, hard-deletes rules without
    /// deletedDate, and never enters this set.
    static func tombstones<K: OwnedItemKind>(_ kind: K.Type, locals: [K.Local],
                                             table: PhiOwnedItemTable, resolve: OwnerResolver,
                                             scope: PinnedTabScope?,
                                             nowMs: Int64,
                                             pendingClaims: Set<String> = [],
                                             explicitDeletions: Set<String> = [],
                                             deferredDeletions: Set<String> = [])
        -> OwnedItemTombstoneResult {
        // Append new defaulted arguments after pendingClaims to preserve bookmark/pin callers.
        // The eighth argument deferredDeletions guards §8.4.4 β (R-M3-4a-84 / ruling 5):
        // a local deletion being reconsidered while its live arrival is parked for
        // nonquiescent W must send no tombstone this round. Guard before diffing,
        // which clears pendingApply and sets pendingDelete. The engine applies
        // cursorUpdates before constructing deleteCandidates, too late for that guard there.
        var liveIdentities: Set<String> = []
        for local in locals {
            if let identity = K.identity(of: local, resolve: resolve, scope: scope) {
                liveIdentities.insert(identity)
            }
        }

        var identities: [String] = []
        var cursorUpdates: [String: PhiOwnedItemCursor] = [:]
        for (identity, cursor) in table.cursors {
            // Guard 0 (R-M3-4a-84): omit identity and cursor updates, preserving pendingApply,
            // pendingOwnerUuid, pendingDelete, and deleteDecidedAtMs. Run before all
            // three criteria and cursor bookkeeping.
            guard !deferredDeletions.contains(identity) else { continue }
            guard cursor.reconciled != nil else { continue }
            guard cursor.deletedAtMs == nil else { continue }
            guard !liveIdentities.contains(identity) else { continue }
            // Matched for adoption this round, awaiting only successful persistence (R-exec-9).
            guard !pendingClaims.contains(identity) else { continue }
            // Origin b identities bypass these two ownership gates (R-M3-4a-78).
            if !explicitDeletions.contains(identity) {
                // Nil ownerUuid is unknown ownership, never permission to delete. The engine
                // must refresh it each round (A12 / §3.5); nil indicates an unmet prerequisite
                // this module cannot verify. Conservatively retaining one stale account entity
                // is preferable to deleting an entire Space's bookmarks.
                guard let owner = cursor.ownerUuid else { continue }
                // Unmapped owner. App-scope pins use a literal ownerKey requiring no stored
                // mapping; Task 4b must either avoid that literal in cursor.ownerUuid or
                // have the engine resolver map it to itself.
                let mapped = resolve.localSpaceId(owner) != nil || resolve.localProfileId(owner) != nil
                guard mapped else { continue }
                // Ineligible hidden/purged owner.
                guard resolve.localSpaceId(owner) == nil || resolve.isEligibleSpace(owner) else { continue }
            }
            identities.append(identity)
            var updated = cursor
            updated.pendingApply = nil
            updated.pendingOwnerUuid = nil
            updated.pendingDelete = true
            // Write deletion-decision time once. A pending-delete cursor may also hold
            // a blocked pending arrival, since planning parks before reaching deletion
            // handling. Restamping would continually advance A9's comparison boundary
            // and prevent concurrent moves from cancelling deletion.
            //
            // C2 / R2.1: `nowMs` here is the HYBRID LOGICAL clock, not wall clock. A9 below
            // compares this field against `K.locationStamp(of: merged)`, an LWW wire stamp. If
            // the two clocks diverge -- this one on wall time while stamps run on logical time
            // that has pulled ahead of it -- every inbound entity looks newer than the deletion
            // and A9 cancels every local delete. The engine's `tombstones(...)` call site
            // passes `hlcNow()` for exactly this reason. `deletedAtMs` is the opposite: it
            // drives the 30-day retention expiry and stays wall clock.
            if !cursor.pendingDelete { updated.deleteDecidedAtMs = nowMs }
            if updated != cursor { cursorUpdates[identity] = updated }
        }

        // §5.3 reverse topological order: children before parents. Baselines are
        // the only parent-reference source because tombstones have no payload.
        var parentOf: [String: String] = [:]
        for identity in identities {
            guard let bytes = table.cursors[identity]?.reconciled,
                  let envelope = try? Phi_PhiEntity(serializedBytes: bytes),
                  let entity = K.entity(from: envelope) else { continue }
            if let parent = K.ownerUuids(of: entity).first(where: { table.cursors[$0] != nil }) {
                parentOf[identity] = parent
            }
        }
        let depths = depth(of: identities, parentOf: parentOf)
        identities.sort {
            let left = depths[$0] ?? 0, right = depths[$1] ?? 0
            return left == right ? $0 < $1 : left > right
        }
        return OwnedItemTombstoneResult(identities: identities, cursorUpdates: cursorUpdates,
                                        deferred: deferredDeletions)
    }

    // MARK: - Inbound plan (§4.4)

    /// Current arrivals plus parked items produce a plan ordered in four phases
    /// (R-M3-4a-93). Bookmark dependencies are arbitrarily deep peer entities
    /// within one data type; topological ordering applies an out-of-order tree
    /// in one round instead of one round per level.
    static func plan<K: OwnedItemKind>(_ kind: K.Type,
                                       arrivals: [OwnedItemArrival<K.Entity>],
                                       parked: [String: ParkedOwnedItem],
                                       table: PhiOwnedItemTable,
                                       resolve: OwnerResolver,
                                       context: OwnedItemPlanContext) -> OwnedItemPlan {
        // Harvest first, whether the entity is later discarded, refused, or parked
        // (A6). Losing server entityId/version produces stale-version deletion
        // retries every 60 seconds with no successful application.
        var harvest: [String: (entityId: String, version: Int64)] = [:]
        for item in arrivals {
            let identity = K.identity(of: item.entity)
            guard !identity.isEmpty else { continue }
            let previous = harvest[identity]
            harvest[identity] = (entityId: item.entityId.isEmpty ? (previous?.entityId ?? "")
                                                                 : item.entityId,
                                 version: max(item.version, previous?.version ?? 0))
        }

        func payloadBytes(_ entity: K.Entity) -> Data? {
            try? K.envelope(entity).serializedData()
        }

        // §7.3 scope mismatch parks all inbound entities with zero steps. Park
        // tombstones too (§12.1 item 15), using parkedTombstones identities because
        // they carry only tag hashes (§2.5). Parking live payloads alone loses
        // remote deletions permanently after the marker advances beyond their page.
        if context.scopeMismatch {
            var parkedOut = parked
            for item in arrivals {
                let identity = K.identity(of: item.entity)
                guard !identity.isEmpty, let payload = payloadBytes(item.entity) else { continue }
                parkedOut[identity] = ParkedOwnedItem(
                    payload: payload, pendingOwnerUuid: K.ownerUuids(of: item.entity).first)
            }
            return OwnedItemPlan(steps: [], parked: parkedOut, refused: 0, lifted: 0,
                                 supersededByDelete: 0, cancelledDeletes: [], harvest: harvest,
                                 parkedTombstones: context.tombstonedIdentities)
        }

        // 1. Working set: parked items in device-independent UUID order plus current
        // arrivals, which replace parked copies of the same identity. Preserve
        // undecodable parked bytes unchanged.
        var working: [(identity: String, entity: K.Entity)] = []
        var slotOf: [String: Int] = [:]
        var parkedOut: [String: ParkedOwnedItem] = [:]
        for identity in parked.keys.sorted() {
            guard let item = parked[identity] else { continue }
            guard let envelope = try? Phi_PhiEntity(serializedBytes: item.payload),
                  let entity = K.entity(from: envelope) else {
                parkedOut[identity] = item
                continue
            }
            slotOf[identity] = working.count
            working.append((identity, entity))
        }
        var refused = 0
        for item in arrivals {
            let identity = K.identity(of: item.entity)
            // §4.6 first criterion: refuse empty UUID and count it, so a repeatedly
            // malformed sender remains visible in diagnostics.
            guard !identity.isEmpty else { refused += 1; continue }
            if let slot = slotOf[identity] {
                working[slot] = (identity, item.entity)
            } else {
                slotOf[identity] = working.count
                working.append((identity, item.entity))
            }
        }

        // 2. Refusals and tombstone precedence. A child's own tombstone replaces
        // its live entity here, ensuring deletion rather than promotion.
        func baselineOf(_ identity: String) -> K.Entity? {
            guard let bytes = table.cursors[identity]?.reconciled,
                  let envelope = try? Phi_PhiEntity(serializedBytes: bytes) else { return nil }
            return K.entity(from: envelope)
        }

        var survivors: [(identity: String, entity: K.Entity)] = []
        for item in working {
            if context.tombstonedIdentities.contains(item.identity) { continue }
            // Pass baseline to refuses for is_folder mismatch against the existing
            // local entity. This is an invariant, not a field to resolve through LWW.
            if K.refuses(item.entity, baseline: baselineOf(item.identity)) != nil {
                refused += 1
                continue
            }
            survivors.append(item)
        }
        let survivorIdentities = Set(survivors.map(\.identity))

        // 3. Classify ownership. Mere parent absence never promotes: decryption
        // failure, refusal, parking, or later pages can all explain it. Otherwise
        // one invalid ciphertext could irreversibly flatten a whole account subtree.
        func classify(_ uuid: String) -> OwnerState {
            if survivorIdentities.contains(uuid) { return .item(uuid) }
            if context.tombstonedIdentities.contains(uuid)
                || table.cursors[uuid]?.deletedAtMs != nil { return .lift }
            if context.liveLocalParents.contains(uuid) { return .external }
            if resolve.localSpaceId(uuid) != nil { return resolve.isEligibleSpace(uuid) ? .external : .unresolved }
            if resolve.localProfileId(uuid) != nil { return .external }
            return .unresolved
        }

        // 4. Kahn topological sort. Refuse remaining cyclic dependencies as remote
        // bugs or forged payloads; parking waits forever for impossible parents.
        var dependencies: [String: [String]] = [:]
        for item in survivors {
            dependencies[item.identity] = K.ownerUuids(of: item.entity).compactMap {
                if case .item(let parent) = classify($0), parent != item.identity { return parent }
                return nil
            }
        }
        var ordered: [(identity: String, entity: K.Entity)] = []
        var placed: Set<String> = []
        var remaining = survivors
        while true {
            var progressed = false
            var stillRemaining: [(identity: String, entity: K.Entity)] = []
            for item in remaining {
                let ready = (dependencies[item.identity] ?? []).allSatisfy { placed.contains($0) }
                if ready {
                    ordered.append(item)
                    placed.insert(item.identity)
                    progressed = true
                } else {
                    stillRemaining.append(item)
                }
            }
            remaining = stillRemaining
            if remaining.isEmpty || !progressed { break }
        }
        refused += remaining.count      // Cycles

        // 5. Apply in topological order.
        var steps: [OwnedItemApplyStep] = []
        var lifted = 0
        var supersededByDelete = 0
        var cancelledDeletes: Set<String> = []
        var mustRepublish: Set<String> = []
        var rebaselined: [String: Data] = [:]
        var preLandingSignatures: [String: RuleSignature] = [:]
        var landedIdentities: Set<String> = []
        // §8.4.4 locals (8b-3): α populates in section 6, β in the following A9/L1 branch.
        var parkedTombstonesOut: Set<String> = []
        var yieldedTombstones: Set<String> = []

        for item in ordered {
            let identity = item.identity
            var landingParent: String?
            var wasLifted = false
            var blockedBy: String?
            for owner in K.ownerUuids(of: item.entity) {
                switch classify(owner) {
                case .item(let parent):
                    if landedIdentities.contains(parent) {
                        landingParent = parent
                    } else {
                        blockedBy = owner      // The parent is parked, refused, or cyclic
                    }
                case .lift:
                    wasLifted = true
                    landingParent = ""
                case .external:
                    continue
                case .unresolved:
                    blockedBy = owner
                }
                if blockedBy != nil { break }
            }

            if let blockedBy {
                if let payload = payloadBytes(item.entity) {
                    parkedOut[identity] = ParkedOwnedItem(payload: payload,
                                                          pendingOwnerUuid: blockedBy)
                }
                continue
            }

            let cursor = table.cursors[identity]
            let baseline = baselineOf(identity)
            // Adopted identities use §6.2 field merges supplied through context. Their
            // local rows have no baseline, so ordinary baseline merging would degrade
            // to forbidden wholesale remote adoption and silently erase join-time edits.
            let adopted: K.Entity? = context.adoptedMerges[identity].flatMap {
                guard let envelope = try? Phi_PhiEntity(serializedBytes: $0) else { return nil }
                return K.entity(from: envelope)
            }
            // Use the current local projection for the local merge side, falling back
            // to baseline only when absent. Baselines represent the previous sync;
            // using them directly would overwrite unpublished local edits whenever the
            // remote changes any field of the entity.
            let localProjection: K.Entity? = context.localProjections[identity].flatMap {
                guard let envelope = try? Phi_PhiEntity(serializedBytes: $0) else { return nil }
                return K.entity(from: envelope)
            }
            let merged = adopted
                ?? localProjection.map { K.merge(local: $0, remote: item.entity) }
                ?? baseline.map { K.merge(local: $0, remote: item.entity) }
                ?? item.entity
            // When local location wins, apply the merged parent rather than the losing
            // remote parent. Otherwise local state differs from reconciled and republishes
            // a second move next round. nil means use the merged payload's parent;
            // explicit promotion via wasLifted remains authoritative.
            if !wasLifted, landingParent != nil,
               K.ownerUuids(of: merged) != K.ownerUuids(of: item.entity) {
                landingParent = nil
            }

            // §5.6 L1: a live arrival meets a pending-delete cursor.
            if cursor?.pendingDelete == true {
                // §8.4.4 β (8b-3 / ruling 1): pendingDelete, existing row including soft
                // deletions, signature, and quiescent W. The first three are encoded in
                // mergePartners/partnerNotAtRest domains. Do not copy α's live-row or dirty
                // disjunction criteria (RR8-1): β rows are absent or soft-deleted, and on
                // the merging device the loser lacks local edits while conflict leaves
                // baselines unchanged. Those extra criteria would make β unreachable,
                // fall back to cancelledDeletes, and leave two different-signature rules.
                if K.tombstoneYieldsToLocalEdits {
                    if let partner = context.mergePartners[identity],
                       let source = K.transferSource(of: merged, resolve: resolve) {
                        // i. Transfer from this round's merged inbound entity, not the local row: in
                        // race 2, M2 soft-deleted the local row with its old target, while retarget
                        // intent exists only in the arrival. Do not cancel deletion or apply X:
                        // preserve soft deletion, mergePartnerSyncId, and pendingDelete (RR9-1).
                        // Application would clear the pointer/state needed to reconsider transfer
                        // next round, while the pending tombstone eventually hard-deletes X.
                        steps.append(OwnedItemApplyStep(identity: identity,
                                                        kind: .transfer(source: source,
                                                                        to: partner),
                                                        newParentUuid: nil, newRank: nil,
                                                        payload: nil))
                        continue
                    }
                    if context.partnerNotAtRest.contains(identity) {
                        // A present but nonquiescent W parks the live arrival as pendingApply.
                        // Never set parkedTombstones/pendingTombstone here; those belong to α.
                        if let payload = payloadBytes(item.entity) {
                            parkedOut[identity] = ParkedOwnedItem(
                                payload: payload,
                                pendingOwnerUuid: K.ownerUuids(of: item.entity).first)
                        }
                        continue
                    }
                }
                // Both sides are hybrid-logical values (C2 / R2.1): the left is a wire LWW
                // stamp, the right was written from `hlcNow()` in `tombstones(...)` above.
                // They must stay on the same clock or this comparison loses its meaning.
                let decidedAt = cursor?.deleteDecidedAtMs ?? 0
                let newerThanDeletion = K.locationStamp(of: merged) > decidedAt
                let parentIsLive = landingParent.map {
                    $0.isEmpty || landedIdentities.contains($0) || context.liveLocalParents.contains($0)
                } ?? true
                let outsideDeletedSubtree = !context.deletedSubtree.contains(identity)
                    && !(landingParent.map { context.deletedSubtree.contains($0) } ?? false)
                // A9: newer inbound location moving to a live parent outside the deleted
                // subtree cancels deletion. Discard other updates; local deletion wins.
                guard newerThanDeletion, parentIsLive, outsideDeletedSubtree else {
                    supersededByDelete += 1
                    continue
                }
                cancelledDeletes.insert(identity)
            }

            if wasLifted { lifted += 1 }
            landedIdentities.insert(identity)
            let payload = payloadBytes(merged)
            let rank = K.rank(of: merged)
            // Ordinary-update §6.2 republication: merged differs from the account entity
            // when local wins something. Compare the whole entity, including location/rank
            // outside the content signature. Adoption computes its own mustRepublish
            // because its local side has no baseline.
            if adopted == nil, localProjection != nil, payload != payloadBytes(item.entity) {
                mustRepublish.insert(identity)
            }

            if context.pairs[identity] != nil {
                // §6.3: claim account identity first, then write fields in phase order.
                // Two steps are needed because claim writes only syncId and update carries content.
                steps.append(OwnedItemApplyStep(identity: identity, kind: .claim,
                                                newParentUuid: landingParent, newRank: rank,
                                                payload: payload))
                if context.adoptedFieldWrites.contains(identity) {
                    steps.append(OwnedItemApplyStep(identity: identity, kind: .update,
                                                    newParentUuid: nil, newRank: nil,
                                                    payload: payload))
                }
                continue
            }
            guard let baseline else {
                steps.append(OwnedItemApplyStep(identity: identity, kind: .create,
                                                newParentUuid: landingParent, newRank: rank,
                                                payload: payload))
                continue
            }
            let moved = wasLifted || K.ownerUuids(of: merged) != K.ownerUuids(of: baseline)
                || K.rank(of: merged) != K.rank(of: baseline)
            if moved {
                // Populate newOwnerUuid from merged ownership only for move (R-M3-4a-26).
                // Leave it absent for claim/create/update/delete; create reads its target from payload.
                steps.append(OwnedItemApplyStep(identity: identity, kind: .move,
                                                newParentUuid: landingParent,
                                                newOwnerUuid: K.targetOwnerUuid(of: merged),
                                                newRank: rank, payload: payload))
                // Capture the pre-application signature when emitting this step for D30's
                // second grouping pass (§8.4.3 step 1 / ruling 2). Unavailable signatures remain absent.
                if let key = context.localSignatures[identity] {
                    preLandingSignatures[identity] = key
                }
            }
            // Move and content update are separate, not mutually exclusive. Bookmark
            // move carries no patch, so omitting update after a rename loses the remote
            // edit and republishes the old local title next round without a diagnostic.
            // Compare content signatures, not full entities; timestamp-only changes
            // must not generate empty patches.
            let contentChanged = K.contentSignature(of: merged)
                != K.contentSignature(of: baseline)
            if contentChanged {
                steps.append(OwnedItemApplyStep(identity: identity, kind: .update,
                                                newParentUuid: nil, newRank: nil, payload: payload))
                // Likewise capture on update (ruling 2). Recording the same identity for
                // both move and update is idempotent because the signature is identical.
                if let key = context.localSignatures[identity] {
                    preLandingSignatures[identity] = key
                }
            }
            // No steps but a changed merged baseline means timestamps differ; advance
            // baseline (see rebaselined). Check after both step-producing branches to
            // establish that nothing needs application.
            if !moved, !contentChanged, let payload,
               payload != table.cursors[identity]?.reconciled {
                rebaselined[identity] = payload
            }
        }

        // 6. Current remote tombstones, child-first in §4.4's fourth phase.
        var deleteParentOf: [String: String] = [:]
        for identity in context.tombstonedIdentities {
            var entity: K.Entity?
            if let slot = slotOf[identity], slot < working.count { entity = working[slot].entity }
            if entity == nil, let bytes = table.cursors[identity]?.reconciled,
               let envelope = try? Phi_PhiEntity(serializedBytes: bytes) {
                entity = K.entity(from: envelope)
            }
            guard let entity else { continue }
            if let parent = K.ownerUuids(of: entity).first(where: {
                context.tombstonedIdentities.contains($0) || table.cursors[$0] != nil
            }) {
                deleteParentOf[identity] = parent
            }
        }
        let tombstoned = Array(context.tombstonedIdentities)
        let depths = depth(of: tombstoned, parentOf: deleteParentOf)
        for identity in tombstoned.sorted(by: {
            let left = depths[$0] ?? 0, right = depths[$1] ?? 0
            return left == right ? $0 < $1 : left > right
        }) {
            // §8.4.4 α (8b-3 / ruling 1): inbound tombstone with a live signed row
            // and pendingLocalEdit or value-based unpublished changes. The sets already
            // encode the first three conditions (§5.6); the module only tests membership.
            if K.tombstoneYieldsToLocalEdits,
               context.pendingLocalEdits.contains(identity)
                || context.unpublished.contains(identity) {
                if let partner = context.mergePartners[identity] {
                    // Quiescent W transfers X's local projection frozen in pre-pass. The
                    // transaction rechecks this source (R-M3-4a-102 / ruling 11), rereading X
                    // by fromSyncId and comparing units. Mismatch skips both transfer/delete
                    // and returns deferredTombstones. Decision ownership stays in pre-pass;
                    // the transaction only checks equality, with no module changes.
                    let projected: K.Entity? = context.localProjections[identity]
                        .flatMap { try? Phi_PhiEntity(serializedBytes: $0) }
                        .flatMap { K.entity(from: $0) }
                    guard let source = projected
                            .flatMap({ K.transferSource(of: $0, resolve: resolve) }) else {
                        // Missing/undecodable projection follows ii: retain the row without writes
                        // (ruling 3). Parking would set pendingTombstone, exclude snapshot, and
                        // deadlock 3b publication; hard deletion would destroy the local edit.
                        yieldedTombstones.insert(identity)
                        continue
                    }
                    steps.append(OwnedItemApplyStep(identity: identity,
                                                    kind: .transfer(source: source, to: partner),
                                                    newParentUuid: nil, newRank: nil,
                                                    payload: nil))
                    // Continue to emit delete in the same transaction's fourth phase (RR8-5);
                    // phase sorting guarantees transfer executes first regardless of emission order.
                } else if context.partnerNotAtRest.contains(identity) {
                    // Present but nonquiescent W parks the tombstone without delete or row changes.
                    parkedTombstonesOut.insert(identity)
                    continue
                } else {
                    // No partner row follows ii for 3b revival; only this partner-lookup outcome uses ii.
                    yieldedTombstones.insert(identity)
                    continue
                }
            }
            steps.append(OwnedItemApplyStep(identity: identity, kind: .delete,
                                            newParentUuid: nil, newRank: nil, payload: nil))
        }

        // 7. Stable four-phase sort preserves accumulated topological/reverse-topological order within phases.
        let sorted = steps.enumerated().sorted { lhs, rhs in
            let lhsPhase = phase(lhs.element.kind), rhsPhase = phase(rhs.element.kind)
            return lhsPhase == rhsPhase ? lhs.offset < rhs.offset : lhsPhase < rhsPhase
        }.map(\.element)

        return OwnedItemPlan(steps: sorted, parked: parkedOut, refused: refused, lifted: lifted,
                             supersededByDelete: supersededByDelete,
                             cancelledDeletes: cancelledDeletes, harvest: harvest,
                             mustRepublish: mustRepublish,
                             // RR9-15: normal returns must carry both sets. Per-identity α parking
                             // coexists with application elsewhere on the page; default empty sets
                             // would silently lose it.
                             parkedTombstones: parkedTombstonesOut,
                             yieldedTombstones: yieldedTombstones,
                             rebaselined: rebaselined,
                             preLandingSignatures: preLandingSignatures)
    }

    // MARK: - Adoption (§6 rule i)

    /// D10 rule i applies only to bookmarks (§6.7 excludes pins): an inbound
    /// entity matched to a nil-syncId local row claims that UUID through in-place
    /// update rather than creation. There is no second rule: sync never removes
    /// or merges published lookalikes (R-M3-3-28). Former automatic collapse
    /// merged sibling folders sharing a placeholder URL and displaced their
    /// children to the Space root. This function deletes nothing and drops no
    /// arrival; unmatched arrivals create rows, while unmatched locals mint identities.
    ///
    /// Match top-down from mapped Space roots and already-identified local anchors
    /// for cross-round continuity (§6.3). Group each level by full key, URL for
    /// bookmarks or title for folders, then pair local index order with remote
    /// rank order. Grouping by only Space/path could pair different URLs.
    static func adopt(arrivals: [Phi_PhiBookmarkEntity], locals: [PhiLocalBookmark],
                      resolve: OwnerResolver) -> OwnedItemAdoptionResult {
        var pairs: [String: String] = [:]
        var unmatchedFolders = 0
        var merges: [String: Data] = [:]
        var mustRepublish: Set<String> = []
        var fieldWrites: Set<String> = []
        var unmergeablePairs = 0

        var localByGuid: [String: PhiLocalBookmark] = [:]
        var localGuidByIdentity: [String: String] = [:]
        for local in locals {
            localByGuid[local.guid] = local
            if let identity = local.syncId { localGuidByIdentity[identity] = local.guid }
        }
        var arrivalsByParent: [String: [Phi_PhiBookmarkEntity]] = [:]
        for entity in arrivals {
            arrivalsByParent[entity.parentUuid.stringValue, default: []].append(entity)
        }

        var queue: [(remoteParent: String, localParentGuid: String?, localSpaceId: String)] = []
        var visited: Set<String> = []
        func enqueue(_ remoteParent: String, _ localParentGuid: String?, _ localSpaceId: String) {
            let key = remoteParent + "\u{0}" + (localParentGuid ?? "") + "\u{0}" + localSpaceId
            guard visited.insert(key).inserted else { return }
            queue.append((remoteParent, localParentGuid, localSpaceId))
        }

        /// §6.2 field merge. Project local without baseline: content uses
        /// contentUpdatedDate ?? createdDate; location/rank use zero and yield to
        /// real remote stamps. Never substitute updatedDate, which lastSeen/favicon/index
        /// maintenance advances without edits and could let stale local content win.
        /// Record a successful merge and return true; failure invalidates the pair.
        /// Never fall back to wholesale remote adoption and erase join-time edits
        /// during owner-resolution fluctuations. The local row remains unsynced
        /// for retry, and the arrival creates its own row normally.
        func recordMerge(_ entity: Phi_PhiBookmarkEntity, _ row: PhiLocalBookmark) -> Bool {
            let parentIdentity = entity.parentUuid.stringValue
            guard var projected = BookmarkKind.project(row, resolve: resolve, scope: nil,
                                                       parentIdentity: parentIdentity.isEmpty
                                                           ? nil : parentIdentity) else {
                return false
            }
            // now/hlcMax are both 0 on purpose: this projection is the LOCAL SIDE of an adoption
            // merge, not a publication. Location and rank must stay at stamp 0 so a derived local
            // position cannot beat the arrival, and content keeps its bare edit time so an old
            // untouched local row cannot claim the account's logical time during claiming.
            projected = BookmarkKind.stamp(projected, baseline: nil, local: row,
                                           rank: "", now: 0, hlcMax: 0)
            // The unidentified local projection has an empty UUID; the merge adopts the remote UUID.
            let merged = BookmarkKind.merge(local: projected, remote: entity)
            guard let bytes = try? BookmarkKind.envelope(merged).serializedData() else {
                return false
            }
            merges[entity.bookmarkUuid] = bytes
            // A merge differing from the account entity means a local field won and requires republication.
            if merged != entity { mustRepublish.insert(entity.bookmarkUuid) }
            // Merged content differing from the current row requires field writes during application.
            if BookmarkKind.contentSignature(of: merged)
                != BookmarkKind.contentSignature(of: projected) {
                fieldWrites.insert(entity.bookmarkUuid)
            }
            return true
        }

        // Starting point ①: every mapped Space root.
        for entity in arrivalsByParent[""] ?? [] {
            if let spaceId = resolve.localSpaceId(entity.spaceUuid.stringValue) {
                enqueue("", nil, spaceId)
            }
        }
        // Starting point ②: an identified local row anchors its children across
        // round slices, without a window. Running only on first Space merge would
        // create duplicate rows for arrivals in later rounds.
        for entity in arrivals {
            let parent = entity.parentUuid.stringValue
            guard !parent.isEmpty, let guid = localGuidByIdentity[parent],
                  let row = localByGuid[guid] else { continue }
            enqueue(parent, guid, row.spaceId)
        }

        var head = 0
        while head < queue.count {
            let level = queue[head]
            head += 1

            var candidates: [Phi_PhiBookmarkEntity] = []
            for entity in arrivalsByParent[level.remoteParent] ?? [] {
                // Filter root-level arrivals by Space too; empty parent_uuid spans every account Space.
                if level.remoteParent.isEmpty,
                   resolve.localSpaceId(entity.spaceUuid.stringValue) != level.localSpaceId {
                    continue
                }
                // Already-claimed entities do not pair because rule i only claims nil-syncId
                // rows, but they remain anchors for their children.
                if let guid = localGuidByIdentity[entity.bookmarkUuid] {
                    if entity.isFolder, let row = localByGuid[guid] {
                        enqueue(entity.bookmarkUuid, guid, row.spaceId)
                    }
                    continue
                }
                candidates.append(entity)
            }
            let localChildren = locals.filter {
                $0.syncId == nil && $0.spaceId == level.localSpaceId
                    && $0.parentGuid == level.localParentGuid
            }

            // Group folders by title, never URL: all local folders share one placeholder,
            // which would otherwise make every sibling folder look identical.
            unmatchedFolders += pairWithinGroups(
                remote: candidates.filter(\.isFolder),
                local: localChildren.filter(\.isFolder),
                remoteKey: { $0.title.stringValue },
                localKey: { $0.title }) { entity, row in
                    guard recordMerge(entity, row) else { unmergeablePairs += 1; return }
                    pairs[entity.bookmarkUuid] = row.guid
                    enqueue(entity.bookmarkUuid, row.guid, row.spaceId)
                }
            // Group bookmarks by URL.
            _ = pairWithinGroups(
                remote: candidates.filter { !$0.isFolder },
                local: localChildren.filter { !$0.isFolder },
                remoteKey: { $0.url.stringValue },
                localKey: { $0.url.absoluteString }) { entity, row in
                    guard recordMerge(entity, row) else { unmergeablePairs += 1; return }
                    pairs[entity.bookmarkUuid] = row.guid
                }
        }
        return OwnedItemAdoptionResult(pairs: pairs, adopted: pairs.count,
                                       unmatchedFolders: unmatchedFolders,
                                       merges: merges, mustRepublish: mustRepublish,
                                       fieldWrites: fieldWrites,
                                       unmergeablePairs: unmergeablePairs)
    }

    /// One-to-one pairing within a level: group by full key, then align local
    /// index order with remote rank order. Pair by each side's user-visible
    /// position rather than arbitrarily. Return the number of unmatched arrivals.
    private static func pairWithinGroups(remote: [Phi_PhiBookmarkEntity],
                                         local: [PhiLocalBookmark],
                                         remoteKey: (Phi_PhiBookmarkEntity) -> String,
                                         localKey: (PhiLocalBookmark) -> String,
                                         pair: (Phi_PhiBookmarkEntity, PhiLocalBookmark) -> Void)
        -> Int {
        var remoteGroups: [String: [Phi_PhiBookmarkEntity]] = [:]
        for entity in remote { remoteGroups[remoteKey(entity), default: []].append(entity) }
        var localGroups: [String: [PhiLocalBookmark]] = [:]
        for row in local { localGroups[localKey(row), default: []].append(row) }

        var leftOver = 0
        for (key, entities) in remoteGroups {
            let orderedRemote = entities.sorted {
                let left = $0.rank.stringValue, right = $1.rank.stringValue
                return left == right ? $0.bookmarkUuid < $1.bookmarkUuid : left < right
            }
            let orderedLocal = (localGroups[key] ?? []).sorted {
                $0.index == $1.index ? $0.guid < $1.guid : $0.index < $1.index
            }
            for (offset, entity) in orderedRemote.enumerated() {
                if offset < orderedLocal.count { pair(entity, orderedLocal[offset]) }
                else { leftOver += 1 }
            }
        }
        return leftOver
    }

    // MARK: - Private helpers

    /// Four phases: claim/create/move, update, transfer, delete (R-M3-4a-93).
    /// Transfer compares LWW against W after update and runs before hard-deleting X;
    /// see StepKind for the boundary rationale.
    private static func phase(_ kind: StepKind) -> Int {
        switch kind {
        case .claim, .create, .move: return 1
        case .update: return 2
        case .transfer: return 3
        case .delete: return 4
        }
    }

    /// Walk parentOf to the root, bounded by its entry count. Cycles therefore
    /// have finite depth instead of hanging the sort.
    private static func depth(of identities: [String], parentOf: [String: String]) -> [String: Int] {
        var out: [String: Int] = [:]
        let limit = parentOf.count
        for identity in identities where out[identity] == nil {
            var hops = 0
            var cursor = parentOf[identity]
            while let parent = cursor, hops < limit {
                hops += 1
                cursor = parentOf[parent]
            }
            out[identity] = hops
        }
        return out
    }
}

import CryptoKit
import Foundation

/// The engine's view of the domain key. `PhiDomainKeyManager` is a concrete final class with
/// no seam of its own, so the abstraction lives here — the same shape as
/// `protocol KeyEnvelopeAPI` / `extension KeyEnvelopeAPIClient: KeyEnvelopeAPI {}`.
protocol PhiDomainKeyProviding: AnyObject {
    func domainKey() async throws -> SymmetricKey
}

/// The witness is `@MainActor` (see `PhiDomainKeyManager`), which an `async` requirement
/// accepts: the engine's `await domainKeys.domainKey()` becomes a hop onto the main actor,
/// which is exactly the point — it keeps the M2 key layer main-actor-confined.
extension PhiDomainKeyManager: PhiDomainKeyProviding {}

/// Metadata-only rendering of an error for the shipped log (design §8 / ruling R12).
///
/// A bare `\(error)` is not safe here: `KeyAPIError.http(Int, String)` carries the server's
/// raw response body, and the key endpoints answer with sealed envelopes, so interpolating the
/// whole value would put payload bytes into a log file support asks users to send. The cases
/// enumerated below are all metadata by construction; everything else degrades to the error's
/// type plus its bridged domain/code rather than its description.
enum PhiSyncLog {
    static func describe(_ error: Error) -> String {
        switch error {
        case let error as KeyAPIError:
            switch error {
            case .http(let status, _): return "KeyAPIError.http(\(status))"
            case .transport(let underlying): return "KeyAPIError.transport(\(describe(underlying)))"
            case .decode: return "KeyAPIError.decode"
            case .lastActiveDevice: return "KeyAPIError.lastActiveDevice"
            }
        case let error as PhiSyncProtocolError:
            // Every case carries an HTTP status or a protocol enum, never content.
            return String(describing: error)
        case let error as CryptoKitError:
            return String(describing: error)
        case let error as ProfileKeyManagerError:
            return String(describing: error)
        default:
            let bridged = error as NSError
            return "\(type(of: error))(domain=\(bridged.domain) code=\(bridged.code))"
        }
    }
}

/// A row in the pairing wizard's step-2 Account column (R-D6-1). This is a transient UI preview,
/// not persisted sync state.
struct PhiAccountSpaceSummary: Equatable, Sendable {
    let syncUuid: String
    let name: String
    let iconName: String
    let colorHex: String
    /// Account-global Profile UUID; the default Space uses an empty string.
    let profileUuid: String
    /// Always false in returned previews: section 4.3(6) excludes the entire default Space.
    /// Retained to make the filtering boundary explicit and directly testable.
    let isDefault: Bool
    // D7 / R-D7-1: the overwrite confirmation compares three additional wire fields that step 2
    // does not render. SpaceOverwriteDiff and the view own normalization and display, keeping
    // default-value interpretation in one place. Wire theme_id; an empty string means no pinned
    // theme.
    let themeId: String
    /// Wire opacity in thousandths. Any negative value means no custom opacity; this build sends
    /// -1, while landing accepts all values below zero.
    let overlayOpacityLightMilli: Int64
    let overlayOpacityDarkMilli: Int64
}

enum PhiSpacePreviewError: Error, Equatable {
    /// The coordinator has no engine.
    case engineUnavailable
    case retired
    /// The page budget expired before the account preview was complete. Never return partial
    /// results.
    case truncated
    /// The section 4.5 deadline (PhiSyncEngine.previewDeadlineMs) expired. Check it inside the
    /// round: serialized(_:) uses an unstructured Task that wizard cancellation cannot stop. Racing
    /// Task.sleep only in the UI would leave pagination occupying the round queue.
    case timedOut
    /// Metadata rendered by PhiSyncLog.describe; never includes payloads (R12).
    case transport(String)
}

// MARK: - Owned-item engine integration (M3-3 section 5)
// The engine drives a registry of generic owned kinds. These types describe registry inputs and
// outputs; concrete bookmark/pin behavior belongs in the registration factories below.

/// Identity mappings captured once at round start. This is the value representation of
/// OwnerResolver, whose closures are built by resolver. Values cross into main-actor adapters
/// without requiring the pure-function module to access PhiSpaceSyncTable or mapping stores.
struct OwnedOwnerMaps {
    var syncUuidBySpaceId: [String: String] = [:]
    var localSpaceIdBySyncUuid: [String: String] = [:]
    /// Precomputed conjunction from section 4.2 rule 1: present in currentSpaces(), has a syncUuid,
    /// and its cursor is neither hidden nor purged.
    var eligibleSpaceUuids: Set<String> = []
    var globalUuidByProfileId: [String: String] = [:]
    var localProfileIdByGlobalUuid: [String: String] = [:]
    /// Local spaceId to the Profile that Space is bound to, from `currentSpaces()` (review A4/A5).
    var localProfileIdBySpaceId: [String: String] = [:]

    /// Literal used in the third client-tag segment and ownerUuid for app-scoped pins (sections
    /// 2.4/2.5). It is not a UUID and appears in neither mapping table.
    static let appOwnerKey = "app"

    var resolver: OwnerResolver {
        let maps = self
        // Map the app-owner literal to itself (P1). Otherwise plan, tombstones and snapshot treat
        // app-scoped pins as unresolved: incoming pins remain parked and deleted pins can never
        // publish tombstones. Fix resolution here, not the section 4.7 unresolved-owner deletion
        // safeguard (CASE 4b.4b). Bookmark owners cannot equal this literal.
        // The reserved URL-rule owner incognito-space follows the same rule (R-M3-4a-7, revised):
        // plan, classify, tombstones and move share normal resolution, allowing deleted incognito
        // rules to publish tombstones (CASE U-R1).
        func selfMapped(_ uuid: String, _ table: [String: String]) -> String? {
            if uuid == Self.appOwnerKey { return Self.appOwnerKey }
            if uuid == SyncableSpaces.incognitoSpaceUuid { return SyncableSpaces.incognitoSpaceUuid }
            return table[uuid]
        }
        return OwnerResolver(
            syncUuid: { maps.syncUuidBySpaceId[$0] },
            // Do not map these literals through localSpaceId. Treating app or incognito-space as a
            // local Space would incorrectly subject all app-scoped pins or incognito rules to the
            // Space eligibility gate. Incognito rules have neither a SpaceModel row nor a Space
            // cursor.
            localSpaceId: { maps.localSpaceIdBySyncUuid[$0] },
            isEligibleSpace: { $0 == Self.appOwnerKey
                               || $0 == SyncableSpaces.incognitoSpaceUuid
                               || maps.eligibleSpaceUuids.contains($0) },
            globalUuid: { selfMapped($0, maps.globalUuidByProfileId) },
            localProfileId: { selfMapped($0, maps.localProfileIdByGlobalUuid) },
            localProfileIdForSpace: { maps.localProfileIdBySpaceId[$0] })
    }
}

/// Type-erased outbound snapshot. Entities are serialized Phi_PhiEntity envelopes, compared with
/// each cursor's reconciled bytes for change detection (section 4.2).
struct OwnedSnapshotBytes {
    var entities: [String: Data] = [:]
    /// Identity to the local row's current owner (A12 / section 3.5). Refreshed into
    /// cursor.ownerUuid each round; deletion eligibility and retention cascades read that field.
    var ownerUuids: [String: String] = [:]
    /// Identities minted provisionally in memory this round, mapped to local row IDs. Persist only
    /// after the commit is accepted (section 6.4).
    var minted: [String: String] = [:]
    var skippedUnmappedOwner = 0
    var skippedIneligibleOwner = 0
    /// Whether section 7.3 scope mismatch produced an empty snapshot and suppressed publication.
    /// Only pins set this. Pure push rounds do not run plan, so their scope_mismatch diagnostic
    /// must come from this snapshot.
    var scopeMismatch = false
}

/// Type-erased local answers for the section 9.3 retention cascade. Keep live claims separate from
/// resolvable owners: a mapping failure must not make a live row appear absent and delete its
/// cursor. Losing that cursor would allow a baseVersion-zero create to overwrite account data,
/// violating A12.
struct OwnedLiveRows {
    /// Candidate identities still claimed by a live local row. Section 9.3 condition (b) reads only
    /// this set.
    var claimed: Set<String> = []
    /// Resolvable current owners of those live identities; these are the values used for rehoming.
    var owners: [String: String] = [:]
}

/// Type-erased plan input; incoming entities are envelope bytes.
struct OwnedPlanInput {
    var arrivals: [(payload: Data, entityId: String, version: Int64)] = []
    var parked: [String: ParkedOwnedItem] = [:]
    var table = PhiOwnedItemTable()
    var maps = OwnedOwnerMaps()
    /// Union of this round's incoming tombstone identities and cursors already marked
    /// pendingTombstone.
    var tombstoned: Set<String> = []
    /// The round's single clock reading. Adapters stamp changed local projection fields with now
    /// under section 4.2 rule 4, so the local side of an incoming merge matches what this round's
    /// snapshot would publish (OwnedItemPlanContext.localProjections).
    var now: Int64 = 0
    /// The account's logical time at the start of the round (`PhiHybridClock.maxSeen`). AM-1's
    /// floor for a merge unit with no baseline; 0 means "no floor", which is what every caller
    /// outside the engine wants.
    var hlcMax: Int64 = 0
}

/// Plan output plus counters that only the adapter can compute.
struct OwnedPlanOutput {
    var plan = OwnedItemPlan(steps: [], parked: [:], refused: 0, lifted: 0,
                             supersededByDelete: 0, cancelledDeletes: [], harvest: [:])
    var adopted = 0
    var unmatchedFolders = 0
    var unmergeablePairs = 0
    /// Claimed identities whose merge contains locally winning fields; these must be republished.
    var mustRepublish: Set<String> = []
    /// Owners with incoming entities of this kind in the current pull. Newly minted rows under them
    /// wait until a round with no arrivals for that owner (sections 5.3/6.4). This is a best-effort
    /// optimization, not a correctness gate or persistent window (R-M3-3-22 / CASE 7.4). Values are
    /// the containing Space UUIDs from OwnedSnapshotBytes.ownerUuids, not owners(_:) parent
    /// references.
    var deferredOwners: Set<String> = []
    var scopeMismatch = false
    /// Identity to the remote envelope received this round. The server baseline is always the
    /// remote entity, never the merge result (section 4.5).
    var serverBytes: [String: Data] = [:]
    /// URL-rule identities normalized in place by normalizeArrivals this page (section 13.2 /
    /// R-M3-4a-29). Other kinds leave this zero.
    var normalized = 0
    /// M1 landing addresses: identity to local row ID, from OwnedItemPlanContext.pairs. Landing
    /// converts claim into rekey(localId:to:values:). Empty for bookmarks and pins.
    var claimedLocalIds: [String: String] = [:]
    /// New identity to the old syncId retired by its M1 claim. Remove the old cursor only when
    /// landing actually succeeded; a rolled-back batch still has the old identity on its row.
    var retiredIdentities: [String: String] = [:]
    /// At-rest identities from the page's kind pre-pass (D30 / section 8.4.1; ten conjuncts,
    /// R-M3-4a-86). Evaluate once using that page's allURLRulesIncludingDeleted(), cursor table and
    /// arrivals. The post-write hook cannot recompute it: rows have changed and arrivals are
    /// unavailable (CASE M-27).
    /// This is an upper bound for M2 step-2 candidates (ruling 6). Landing excludes this page's
    /// transfer targets (R-M3-4a-90); the transactional hook excludes newly dirty, soft-deleted or
    /// missing rows (R-M3-4a-100). Empty for bookmarks and pins.
    var atRestIdentities: Set<String> = []
    /// Count of section 8.4.4(ii) decisions with neither mergePartnerSyncId nor a
    /// baselineSignature(X) match (section 13.2 / R-M3-4a-75(3)). Distinguishes expected residuals
    /// from defects (section 14.3 / case 13e). The kind's plan closure counts against the same
    /// pre-pass rows/table at decision time. Never infer this from resurrected, which combines both
    /// causes. Zero for bookmarks and pins.
    var yieldNoPartner = 0
}

struct OwnedLandingInput {
    var steps: [OwnedItemApplyStep] = []
    var table = PhiOwnedItemTable()
    var maps = OwnedOwnerMaps()
    /// OwnedPlanOutput.claimedLocalIds forwarded directly to landing. Empty defaults preserve
    /// bookmark/pin construction sites without a round-state box or new OwnedItemApplyStep field
    /// (ruling 2).
    var claimedLocalIds: [String: String] = [:]

    // MARK: D30 M2's four data channels (8b-2)
    // Defaults keep bookmark and pin landing behavior unchanged; neither kind reads these fields.

    /// Forwarded OwnedItemPlan.preLandingSignatures; grouping key for the second pass of section
    /// 8.4.3 step 1.
    var preLandingSignatures: [String: RuleSignature] = [:]
    /// Forwarded OwnedPlanOutput.atRestIdentities, an upper bound for M2 step-2 candidates. Landing
    /// excludes this page's transfer targets (R-M3-4a-90); the hook excludes newly dirty,
    /// soft-deleted and missing rows transactionally (R-M3-4a-100).
    var atRestIdentities: Set<String> = []
    /// ownedItemsPublishAllowed, including hasDrainedFullReplay, gates section 8.4.3 step 2 only
    /// (R-M3-4a-74(3)). Step-1 pointers and lookups remain outside it. Landing receives this
    /// explicit input because the engine property is private.
    var convergeAllowed = false
    /// OwnedItemPlan.rebaselined, the second effective-account-stamp source (R-M3-4a-97). The
    /// engine updates cursors only after land returns; input.table still holds the older stamp
    /// (CASE M-33(d)).
    var rebaselined: [String: Data] = [:]
}

/// Landing results have three distinct outcomes with different recovery directions; a single
/// failure flag cannot represent them (CASE 6.10c-3).
struct OwnedLandingOutcome {
    /// Identities actually landed and passed the section 4.5 post-landing recheck. Only these may
    /// advance baselines.
    var landed: Set<String> = []
    /// An import lock or another landing error deferred these identities for retry next round.
    var parked: Set<String> = []
    /// Invalid batch plans, such as folderNotEmpty, rowAlreadyMapped or incompatible physical row
    /// types. Refuse without parking or creating cursors.
    var refused: Set<String> = []
    /// Identity to merged bytes to persist as reconciled after landing.
    var reconciled: [String: Data] = [:]
    /// Identities deleted by successfully landed remote tombstones.
    var deleted: Set<String> = []
    /// Partially landed split pairs: identity to the partner lineage still awaited (section 7.4).
    /// Stored as pendingPartnerLineage so doctoredOwnedTable preserves the baseline instead of
    /// publishing an empty link that splits the peer.
    /// An empty string explicitly clears the wait when the partner lands or is removed. A missing
    /// dictionary entry means no update this round, not a cleared wait. Bookmarks leave this empty.
    var pendingPartnerLineages: [String: String] = [:]
    /// Rows whose variant lineage was reminted this round under section 7.2 / A11; zero for
    /// bookmarks.
    var relineaged = 0
    /// Actual surviving move operations that changed the target owner (section 13.2). Count during
    /// landing: URLRuleApplyBatch downgrades unchanged-target moves to reorder, so counting plan
    /// steps overstates this (ruling 3). Zero for bookmarks and pins.
    var ownerMoved = 0
    /// Local bookmark rows newly created by landing and accepted by its post-check (section 8.2 /
    /// Task 10). New rows have no favicon because payloads do not contain one; existing
    /// claimed/updated rows retain their local icons. This criterion avoids extra local reads
    /// solely for backfill. Pins use createdPins instead.
    var createdRows: [PhiLocalBookmark] = []
    /// Newly landed pins eligible for favicon backfill under the same section 8.2 / Task 10 rule.
    /// Both bookmarks and pins are included by the specification.
    var createdPins: [PhiLocalPin] = []
    /// Losers actually soft-deleted by the page's transaction-tail M2 pass (section 8.4.3 step
    /// 2(b), R-M3-4a-54). Feeds OwnedRoundCounters.collapsed; zero for bookmarks and pins.
    var collapsed = 0
    /// M2 changed a soft-delete or content group, requiring one routing refresh for this page even
    /// if no remote entity landed (section 6.6 row 8). Pointer-only writes do not affect routing
    /// (CASE M-7). False for bookmarks and pins.
    var mergeChangedRouting = false
    /// Transfers that wrote at least one merge unit this page (section 13.2, 8b-3 / ruling 9).
    /// Zero-unit transfers do not count; zero for bookmarks and pins.
    var transferred = 0
    /// Transfers whose content group lost this page (section 13.3), included in
    /// superseded_by_delete. Zero for bookmarks and pins.
    var supersededByDelete = 0
    /// Source rows changed before the transaction, so neither transfer nor delete(X) ran
    /// (R-M3-4a-102 / ruling 11). Forward URLRuleBatchOutcome.deferredTombstones and account for
    /// them exactly like plan.parkedTombstones: pendingTombstone=true, no row changes. Never
    /// classify as landed or deleted; that would acknowledge a deletion that did not occur and
    /// allow a new create next round. Empty for bookmarks and pins.
    var deferredTombstones: Set<String> = []
}

/// Result of retrying parked claims (section 3 / R-exec-10).
struct OwnedParkedClaimResult {
    /// Identities matched by section 6 claims this round, regardless of write-back success. Used by
    /// the pendingClaims deletion exemption and to avoid minting another identity for the matched
    /// row.
    var paired: Set<String> = []
    /// Identities successfully written to local rows; clear pendingApply for these.
    var persisted: Set<String> = []
}

/// One section 11.2 counter record per registered kind. Each kind populates and logs only its
/// applicable fields.
struct OwnedRoundCounters {
    var pulled = 0
    var applied = 0
    var parked = 0
    var pushed = 0
    var tombstones = 0
    var adopted = 0
    var unmatchedFolders = 0
    var unmergeablePairs = 0
    var resurrected = 0
    var pendingPublish = 0
    var refused = 0
    var supersededByDelete = 0
    var rehomedCursors = 0
    var unreadable = 0
    var excludedUnmappedOwner = 0
    var localReadFailed = 0
    var relineaged = 0
    var scopeMismatch = false
    // Rule-only section 13.2 counters, selected by reportsRuleCounters; adopted is shared above.
    // Plan reports normalized, landing reports ownerMoved, M2 reports collapsed, and the 8b-3(ii)
    // branch reports transferred/yieldNoPartner. Never derive yieldNoPartner from resurrected
    // afterwards (R-M3-4a-75(3)); steady-state zeros must still be logged.
    var normalized = 0
    var ownerMoved = 0
    var collapsed = 0
    var transferred = 0
    var yieldNoPartner = 0
}

/// Type-erased owned-kind registration. The engine depends only on these registrations, not a fixed
/// set of kinds. Closures bind each OwnedItemKind's pure functions and local access; local closures
/// are MainActor-isolated, matching spaceAccess. Mutable, incrementally learned tag indices belong
/// to engine.ownedTagIndices, not this immutable registration (section 5.1).
struct OwnedKindRegistration {
    /// Unique registry key, log/counter label, and key for ownedTableForTesting and
    /// lastOwnedRoundCountersForTesting.
    let label: String
    let tagPrefix: String
    let entityName: String
    let store: any PhiOwnedItemStateStore
    /// Accessors for this kind's HadRecords/ReplayedForEmptyTable flags in PhiSpaceSyncTable
    /// (section 3.5 single-copy ruling).
    let flags: OwnedKindFlags
    /// Whether to log adopted, unmatched_folders and unmergeable_pairs. Section 11.2 exposes these
    /// only for bookmarks; pins do not use section 6 adoption.
    let reportsAdoption: Bool
    /// Whether to log relineaged and scope_mismatch.
    let reportsScope: Bool
    /// Whether to log the six section 13.2 rule counters: normalized, owner_moved, adopted,
    /// collapsed, transferred and yield_no_partner. Only urlRules enables this (R-M3-4a-55). Do not
    /// infer it from other reporting flags; adding another kind could silently break that
    /// assumption.
    let reportsRuleCounters: Bool
    /// Incoming deletion yields to unpublished local intent for this kind (sections 6.1/8.4.4).
    /// urlRules mirrors URLRuleKind.tombstoneYieldsToLocalEdits; bookmarks and pins use false. The
    /// engine uses this only to enable the round-end rule-3b recheck; the pure module selects
    /// yielding branches from the kind's static property.
    let tombstoneYieldsToLocalEdits: Bool
    /// Whether plan/land runs when arrivals, tombstones and parked entities are all empty
    /// (R-M3-4a-99/56). Only urlRules enables this because M2 convergence must also resolve purely
    /// local duplicates after the initial drain. Bookmark/pin early returns remain unchanged.
    let landsEmptyBatch: Bool

    // MARK: Pure functions (nonisolated)

    /// Return the identity when this envelope contains this kind's payload; otherwise nil.
    let identity: (Phi_PhiEntity) -> String?
    /// Identity to client tag, inverse to identity(of:); used by section 2.5 receiver validation
    /// and batching.
    let clientTag: (String) -> String
    /// Owner references in an envelope: parent/Space for bookmarks, owner for pins. Determine
    /// topological publication and reverse-topological tombstone depth.
    let owners: (Data) -> [String]
    /// Section 7.4 local split removal: clear removed partner links in baseline bytes and stamp
    /// them with this round's now. The third argument is the round-start mapping snapshot also used
    /// by snapshot/tombstones. A nil closure means the kind has no split partners, avoiding all
    /// actor hops and iteration.
    /// Process candidates in one MainActor batch to avoid one hop per cursor. Candidates have a
    /// baseline and no pendingPartnerLineage; return only changed entries, preserving all others.
    /// Check the actual local row: an already landed intact pair also has no pendingPartnerLineage.
    /// Clearing intact links would restamp and republish them every round, exhausting the 250-item
    /// budget.
    /// Stamp removals here: PinKind.stamp cannot distinguish a newly cleared link from an
    /// always-empty projection/baseline. Reusing the old stamp would let the peer's nonempty link
    /// win the lexical tie and restore the split after every sync.
    let clearedSplitPartners: (@MainActor ([String: Data], Int64, OwnedOwnerMaps)
        -> [String: Data])?

    // MARK: Local access (main actor)

    /// Read allBookmarks()/allPins() once at round start. If it throws, skip this kind's snapshot,
    /// diff and publishing without writing its cursor table (R-exec-3).
    let beginRound: @MainActor () throws -> Void
    /// Identities read this round, used to seed the tag index (section 5.1).
    let localIdentities: @MainActor () -> Set<String>
    /// The last two arguments are the round's HLC stamp (`now`) and the logical time it started
    /// from (`hlcMax`), AM-1's floor for a merge unit with no baseline.
    let snapshot: @MainActor (PhiOwnedItemTable, OwnedOwnerMaps, Int64, Int64)
        -> OwnedSnapshotBytes
    /// Section 4.7 deletion diff uses allSyncIds()/allPinRows(), not the snapshot, as its domain
    /// (R-exec-4). Throws if this round's local read failed.
    let tombstones: @MainActor (PhiOwnedItemTable, OwnedOwnerMaps, Int64) throws
        -> OwnedItemTombstoneResult
    /// Retry parked owned-item claims at every round start (section 3 / R-exec-10), immediately
    /// writing matched identities back. Pure push rounds must also do this before publication,
    /// minting and deletion diff can decide whether a row already has an account identity.
    let retryParkedClaims: @MainActor ([String: ParkedOwnedItem], OwnedOwnerMaps) async
        -> OwnedParkedClaimResult
    let plan: @MainActor (OwnedPlanInput) -> OwnedPlanOutput
    let land: @MainActor (OwnedLandingInput) async -> OwnedLandingOutcome
    /// Persist minted identities to local rows only after the commit is accepted (section 6.4).
    /// Return identities actually written.
    let claimIdentities: @MainActor ([String: String]) async -> Set<String>

    /// Section 8.4.5(a): identities whose live publication was applied; applied tombstones are
    /// excluded by the item.payload != nil guard. Re-read and compare all three merge units in the
    /// same row transaction before clearing pendingLocalEdit; clear mergePartnerSyncId as well.
    /// Bookmark and pin registrations use a no-op closure.
    let notePublishApplied: @MainActor (Set<String>) async -> Void
    /// Section 8.4.5(b) receives candidate identities, not baselines (R-M3-4a-96). Generic
    /// publication can compute candidates from cursors/snapshot but cannot access the URL-rule
    /// factory's captured state.publishBaseline. The closure resolves each baseline, drops missing
    /// entries fail-closed, filters pendingLocalEditIdentities, then calls
    /// clearPendingLocalEditIfUnchanged(entries:). The primitive still receives comparison
    /// baselines as required by R-M3-4a-91.
    let clearPendingLocalEdits: @MainActor (Set<String>) async -> Void

    /// The only local read for the section 9.3 retention cascade. Given candidates satisfying (a),
    /// return live claims for (b) separately from their current resolvable owners. Do not use
    /// localIdentities: pins return no identities there because that callback lacks an owner
    /// resolver. Do not use snapshot: it can mint identities or return empty on scope mismatch.
    /// A read failure skips this kind's cascade (R-exec-3), never treating unreadable storage as an
    /// empty database. The domain is the complete allSyncIds()/allPinRows() read (R-exec-4/8),
    /// including unpublished orphan-root and scope-migration backup rows. Such rows are still live
    /// claims.
    let liveOwners: @MainActor (Set<String>, OwnedOwnerMaps) throws -> OwnedLiveRows

    /// First URL-rule soft-delete exit (section 5.7): after persisting the applied tombstone
    /// cursor, hard-delete its local soft-deleted row. Nil means local deletion is already hard for
    /// bookmarks/pins. Failures log only kind/count (R12); the 30-day sweep provides the second
    /// exit.
    var hardDeleteAfterTombstone: (@MainActor (Set<String>) async -> Void)? = nil
    /// Second URL-rule soft-delete exit (section 5.7): retentionSweep removes rows older than 30
    /// days using the row's deletedDate, not cursor.deletedAtMs. A permanently unpublished
    /// tombstone may already have lost its cursor after three rejected retries or never had an
    /// entityId.
    var purgeSoftDeletedRows: (@MainActor (Date) async -> Int)? = nil
}

/// One round of Phi settings sync: pull (GetUpdates -> decrypt -> field-level LWW merge ->
/// apply) and push (snapshot -> encrypt -> Commit), plus the conflict retry and the
/// account-scoped cursor state both need.
///
/// An `actor`, but actor isolation alone does **not** serialize the rounds: Swift actors are
/// reentrant, so every `await` inside a round (the domain key, the network) lets the next
/// message in. The debounced local-change push, the periodic pull, the foreground pull and the
/// conflict retry all mutate the same persisted cursor and the same `UserDefaults` snapshot, so
/// the three public entry points chain onto `roundQueue` and run strictly one after another —
/// see `serialized(_:)`. `PhiDomainKeyManager` is only ever touched from in here.
///
/// Zero knowledge: settings are sealed with the account's PhiBrowser domain key
/// (`PhiEntityCodec` -> `PhiKeyCrypto` AES-GCM) before they reach the protocol client. The
/// field-level last-writer-wins timestamps live inside that ciphertext, so the server orders
/// nothing and reads nothing.
///
/// The engine is single-account and single-use: sign-out must call `shutdown()` (see
/// `PhiChromiumCoordinator.stopPhiSync()`), because dropping the reference alone leaves the
/// rounds already on `roundQueue` running against the shared `phi.sync.*` cursor that the next
/// account is about to claim.
actor PhiSyncEngine {
    // MARK: - Persisted state
    //
    // All account-scoped. The five in `stateKeys` (entity id, version, last entity, tombstone
    // rounds, `hasAdopted`) live in `UserDefaults.standard`, which is not — so account A's
    // entity version must never be replayed against account B. What enforces that is
    // `PhiChromiumCoordinator.resetPhiSyncCursorIfAccountChanged`, which compares the recorded
    // owner against the account being mounted and wipes these keys *before* the engine is
    // built. Sign-out itself only calls `shutdown()`: the cursor is left where it is and either
    // re-adopted by the same account or dropped by that owner check. (`resetSyncState()` below
    // performs the same wipe on demand, but nothing in the app calls it.)
    //
    // The progress marker and the store birthday are the exception as of M3-4a (§2.10 /
    // R-M3-4a-18): they live in the account directory's `sync/marker.json`, beside the
    // per-kind cursor tables, through `markerStore` — so a user-data import that replaces the
    // whole directory rolls the marker back together with the tables. Their two legacy keys
    // are still declared below (`legacyMarkerStateKeys`) because the one-time migration reads
    // them and the account-switch wipe clears them; the engine itself never reads or writes
    // them once a file store is injected.

    static let statePrefix = "phi.sync."
    /// Server-assigned entity id (`id_string`) for the settings entity.
    static let entityIdStateKey = statePrefix + "entityId"
    /// Version last seen for that entity; the `base_version` of the next commit.
    static let versionStateKey = statePrefix + "version"
    /// `store_birthday`, echoed back verbatim on every request once known.
    static let storeBirthdayStateKey = statePrefix + "storeBirthday"
    /// Opaque `DataTypeProgressMarker.token` for data type 2000.
    static let markerStateKey = statePrefix + "marker"
    /// Serialized `Phi_PhiSettingEntity` last known to be on the server. Also carries the keys
    /// this build does not know about, so a newer client's settings survive a round trip
    /// through this one.
    static let lastEntityStateKey = statePrefix + "lastEntity"
    /// Consecutive pulls that found the account's settings row tombstoned. Drives the heal
    /// below; persisted because a tombstone only this process happened to see twice is not
    /// evidence enough to re-create an account's settings.
    static let tombstoneRoundsStateKey = statePrefix + "tombstoneRounds"
    /// Set once this device has settings history for the account. Deliberately *not* part of
    /// the entity cursor: see `hasAdopted`.
    static let hasAdoptedStateKey = statePrefix + "hasAdopted"

    /// The cursor keys that still live in `UserDefaults`. `storeBirthdayStateKey` and
    /// `markerStateKey` left this list in M3-4a: the marker and the birthday are in the
    /// account directory's `marker.json` now, so `resetSyncState()` and the self-revocation
    /// delete that file instead of wiping keys for them.
    /// Review A3: the durable record of a settings entity this device could not read, with the
    /// domain-key fingerprint and build it was refused under. Replaces the marker rewind that
    /// used to re-download the whole data type every round (and block the drain — and with it
    /// every Space and owned-item publication — for as long as the entity stayed unreadable).
    static let unreadableSettingsStateKey = statePrefix + "unreadableSettings"
    /// C2 / R2.1: the hybrid logical clock's `maxSeen`. In `UserDefaults.standard` and
    /// deliberately NOT in the account directory's `marker.json` — the opposite placement
    /// decision from the marker, and for the opposite reason. A user-data import replaces the
    /// account directory, so the marker and the cursor tables roll back together with the
    /// database, which is what they are for. Logical time must not: a rolled-back `maxSeen`
    /// lets this device re-issue stamps the account already holds, so an edit made after the
    /// restore can lose to a value it is trying to overwrite. Still account-scoped, because
    /// logical time is per account, and `stateKeys` is what makes it so.
    static let hlcMaxStateKey = statePrefix + "hlcMax"

    static let stateKeys = [entityIdStateKey, versionStateKey, lastEntityStateKey,
                            tombstoneRoundsStateKey, hasAdoptedStateKey, unreadableSettingsStateKey,
                            hlcMaxStateKey]

    /// The two keys the marker and the birthday lived under before M3-4a. Not in `stateKeys`,
    /// but still on every *account-scope* wipe (`resetPhiSyncCursorIfAccountChanged`, the
    /// self-revocation): a machine whose one-time migration failed to write `marker.json`
    /// keeps these keys for the next launch, and an account switch in between must not let
    /// `PhiSyncMarkerMigration` carry the previous account's marker into the new account's
    /// file — the marker is an opaque per-account token, and requesting a delta with the
    /// wrong account's marker skips that account's history for good.
    static let legacyMarkerStateKeys = [storeBirthdayStateKey, markerStateKey]

    /// GetUpdates pages drained in one pull before the round gives up. 16 was enough for one
    /// settings entity; a first-time Space drain of a busy account is not. The budget still
    /// exists only to stop a pathological `changes_remaining` from spinning forever —
    /// exhausting it ends the ROUND, never the drain (§5.5 guard 1).
    private static let maxPullPages = 64

    /// A page-budget cut queues a follow-up round immediately instead of waiting out the 60 s
    /// timer; bounded so a misbehaving server cannot spin.
    private static let maxFollowUpRounds = 4

    /// Consecutive INVALID_MESSAGE rejections after which a tombstone is finalized anyway
    /// (§5.1). Same shape as `tombstoneHealAfterRounds`.
    private static let tombstoneRejectGiveUpRounds = 3

    /// Stop rearming key-repair after this many consecutive rejected rounds (R-exec-13). As with
    /// deletion retries, tolerate transient failures without republishing permanent failures
    /// forever; the give-up action differs, as documented by PhiOwnedItemCursor.rekeyRejectRounds.
    private static let rekeyRejectGiveUpRounds = 3

    /// The server's `MaxCommitEntries` default is 500; batching well under it keeps one bad
    /// round small.
    private static let maxCommitEntriesPerBatch = 25

    /// Consecutive tombstone pulls after which the entity cursor is dropped so a later local
    /// change can re-create the row. Refusing to publish over a tombstone is right (the delete
    /// must not be undone by the device that merely noticed it), but the refusal is otherwise
    /// account-wide and permanent: the server keeps returning the tombstoned row on every
    /// replay (`internal/data/entities_read.go` FetchUpdates has no `deleted = false` filter,
    /// and `internal/chromiumsync/getupdates.go` toSyncEntity emits it with a non-empty
    /// `id_string`), so `.absent`'s self-heal never fires and every device parks its pushes
    /// forever. Requiring several rounds first keeps a fresh delete sticky; requiring an
    /// explicit local change afterwards (this only clears the cursor, it never publishes)
    /// keeps a deliberate deletion from being resurrected by a device that is merely polling.
    private static let tombstoneHealAfterRounds = 3

    private let domainKeys: any PhiDomainKeyProviding
    private let client: PhiSyncProtocolClient
    private let defaults: UserDefaults
    /// Marker/birthday storage (M3-4a section 2.10). A nil init argument uses
    /// DefaultsBackedPhiSyncMarkerStore for tests or unwired construction sites, reading the two
    /// legacy keys. The production buildPhiSyncEngine constructor supplies FilePhiSyncMarkerStore.
    /// Both accessors share this single engine path without kind-specific branches.
    private let markerStore: any PhiSyncMarkerStore
    /// In-memory marker/birthday mirror loaded once during init. Reads use this mirror;
    /// persistMarkerState writes through with rollback on failure. Reading the file per accessor
    /// would add repeated I/O and misinterpret transient read failures as a nil marker requiring
    /// full replay.
    private var markerState: PhiSyncMarkerFile
    private let deviceKeyId: String
    private let settings: [SyncableSetting]
    /// Wall clock. Keeps everything that is compared against wall clock: the retention sweeps,
    /// `deletedAtMs` / `purgedAtMs` / `refusedAtMs`, the unreadable-tag record, the round
    /// deadlines and `lastProfileRefreshAtMs`. Every LWW STAMP goes through `hlcNow()` instead
    /// (R2.1, "Two clocks, not one").
    private let now: () -> Int64
    /// The account's hybrid logical clock (C2 / R2.1). Mirrors `hlcMaxStateKey`; every advance
    /// writes through `writeState`, which carries the retirement guard, so a stopped engine
    /// cannot push the next account's logical time forward.
    private var hlcClock: PhiHybridClock

    /// The Space section (M3-2). Both are `nil` on a build or an account that has no Space
    /// sync at all, and every Space branch below is gated on them being present, so the M3-1
    /// settings path is byte-for-byte what it was.
    private let spaceAccess: (any PhiSpaceLocalAccess)?
    private let spaceStore: (any PhiSpaceSyncStateStore)?

    /// Mirror of the table's `spaceSectionEnabled`, kept in memory so the shut -> open EDGE is
    /// detectable inside one process too.
    private var spaceSectionEnabled = false

    /// Owned-kind registry (M3-3 section 5). An empty registry skips every owned-item section and
    /// preserves the M3-1/M3-2 behavior of builds without owned-item sync.
    private let ownedKinds: [OwnedKindRegistration]

    /// Optional favicon backfill queue (section 8.2 / Task 10); nil disables backfill. Favicons are
    /// excluded from sync snapshots, so value deduplication absorbs backfill writes without
    /// touching cursors/baselines or triggering publication. The engine feeds it at round end and
    /// stops it during shutdown.
    private let faviconBackfill: PhiFaviconBackfillQueue?

    /// Newly landed favicon candidates collected per round, cleared in run and submitted together
    /// at round end. Bookmark and pin candidates use separate local-access writers.
    private var faviconCandidatesThisRound: [PhiLocalBookmark] = []
    private var faviconPinCandidatesThisRound: [PhiLocalPin] = []

    /// Separate page budget for pairing previews (section 5.8), which must scan account bookmarks
    /// and pins to enumerate all Spaces.
    private let previewMaxPages: Int

    /// Shared default for init. The normal 64 x 500 pull budget spans every kind and tombstones, so
    /// an ordinary account can exhaust it before all Spaces are counted. Preview allows 400 pages;
    /// previewDeadlineMs is the primary bound and the page cap is a fallback.
    static let defaultPreviewMaxPages = 400

    /// Latest preview page/entity counts (section 9.1). Reset at entry and written on every exit,
    /// including early failures. This read-only diagnostic distinguishes truncation from transport
    /// failure without adding payloads to the existing truncated error case.
    private var lastPreviewStats: (pages: Int, entities: Int) = (0, 0)

    /// Kind label to client_tag_hash-to-identity index. Rebuilt from cursors/local identities at
    /// round start, then only grows as ciphertext is decoded, allowing later pages in the same
    /// drain to route tombstones. This mutable per-page state cannot live in immutable
    /// registrations.
    private var ownedTagIndices: [String: [String: String]] = [:]

    /// Per-kind cursor tables. Load at round start, write after apply, then reload for publication
    /// (CASE 6.26 counts these two loads). Also backs ownedTableForTesting without an extra store
    /// load.
    private var ownedTables: [String: PhiOwnedItemTable] = [:]

    /// Kinds whose round-start local read failed (R-exec-3); skip their snapshot, diff, publication
    /// and landing.
    private var ownedReadFailed: Set<String> = []

    /// Per-registered-kind counters for this round (section 11.2).
    private var ownedCounters: [String: OwnedRoundCounters] = [:]

    /// Kinds whose parked claims have already been retried this round. Run once at the start of
    /// owned processing, regardless of whether pull or pushOwnedItems reaches it first.
    private var ownedParkedRetryDone: Set<String> = []

    /// Kinds already initialized this round. Enforces at most one fetch (section 5.7(2)) when
    /// either pull or push can enter first.
    private var ownedRoundStarted: Set<String> = []
    /// Kinds whose cursor table the store reported lost at round entry (review A2). Publication
    /// treats them as lost even after landing has written a partial file back.
    private var ownedLossObservedAtEntry: Set<String> = []

    /// Cached identity mappings for this round, avoiding repeated main-actor round trips.
    private var ownedMapsThisRound: OwnedOwnerMaps?

    /// Claimed identities with locally winning fields (OwnedItemAdoptionResult.mustRepublish).
    /// Without republishing, peers keep the old value while both sides believe they converged.
    private var ownedMustRepublish: [String: Set<String>] = [:]

    /// Best-effort deferred owners from OwnedPlanOutput (section 5.3). Accumulate the union across
    /// all pulls in this round, including birthday and conflict retries. Reset each round and never
    /// persist it: persistence would introduce the cross-round window forbidden by R-M3-3-22.
    private var ownedDeferredOwners: [String: Set<String>] = [:]

    /// §3.6's per-round account profile refresh. `GET /keys/v1/profiles` is small, but App
    /// activation can fire `pullOnce()` far more often than the 60 s timer.
    private static let profileRefreshMinIntervalMs: Int64 = 30_000
    private var didRefreshProfilesThisRound = false
    private var lastProfileRefreshAtMs: Int64 = 0

    /// Follow-up rounds already queued after a page-budget cut, reset by the round that
    /// finally drains. Bounds `maxFollowUpRounds`.
    private var followUpRoundsUsed = 0

    /// Set around `SyncableSettings.apply` so a local-change notification raised by the engine's
    /// own write is not mistaken for a user edit. The load-bearing echo suppression is the
    /// `<key>.phiSyncTs` / `<key>.phiSyncVal` sidecars `apply` maintains; this flag only closes
    /// the window while the write is in flight.
    private var isApplyingRemote = false

    /// No invalidation channel exists yet: only a completed pull in this serialized round
    /// permits publication. Every new pull revokes that permission, including conflict pulls,
    /// so a failed retry cannot leave later entity kinds publishing against stale state.
    private var canPublishThisRound = false

    // B-2 round state (M3-4a Task 2b, sections 2.5/2.8), reset by run. cursorSaveFailures counts
    // failures inside writeSpaceTable, writeOwnedTable, persistMarkerState and the applySpaces
    // mapSpace persistFailed catch. Any such failure blocks publication for the entire round
    // (R-M3-4a-88/92), not merely at the caller that observed it.
    private var cursorSaveFailures = 0
    /// Named section 2.8 outcome. Pull directly assigns cursorSaveFailed, pullFailed,
    /// unusableSettings, pageBudgetExhausted or notMyBirthday; logging derives the other three by
    /// fixed precedence. Later pulls in the same round overwrite earlier assignments.
    private var roundOutcome: RoundOutcome = .ok
    /// Pages fetched across all pulls in this round.
    private var roundPages = 0
    /// Whether the on-disk marker changed this round. Set only after persistStoredMarker succeeds
    /// and storedMarker differs from markerAtEntry (ruling 7).
    private var roundMarkerAdvanced = false
    /// Snapshot captured when logging the round outcome. Not reset at round entry; nil means no
    /// completed round yet. A queued page-budget continuation resets live counters immediately, so
    /// exposing them would make tests observe the next round instead.
    private var lastLoggedRound: LoggedRound?

    /// The four round-log fields, frozen at emission.
    struct LoggedRound {
        let outcome: RoundOutcome
        let pages: Int
        let markerAdvanced: Bool
        let cursorSaveFailures: Int
    }

    /// Tail of the round chain. Each public entry point appends its round to this task and
    /// awaits it, so a round that suspends in `getUpdates` or `commit` still finishes before
    /// the next one starts. Only the public entry points enqueue: the internal `pull` -> `push`
    /// and conflict `push` -> `pull` -> `push` calls run inside an already-queued round and
    /// would deadlock if they queued again.
    private var roundQueue: Task<Void, Never>?

    // MARK: - Shutdown

    /// One-way "this engine is retired" flag, set by `shutdown()` on sign-out / account
    /// switch. From then on no queued round runs, a round already in flight unwinds without
    /// writing anything, and no remote settings are applied.
    ///
    /// It lives in a lock-protected box rather than in actor state so `shutdown()` can be
    /// `nonisolated` and take effect *synchronously*. The sign-out path runs on the main
    /// actor while a round may be parked inside `getUpdates` (URLSession's default timeout is
    /// 60 s) with a debounced push chained behind it; an `await engine.shutdown()` would be
    /// just another message to a reentrant actor, with no ordering against that round's
    /// resumption. With the box, the moment `PhiChromiumCoordinator.stopPhiSync()` returns the
    /// dying round can no longer touch the shared `phi.sync.*` cursor — which the next account
    /// is about to reset and claim in the same `UserDefaults`.
    private final class StopSignal: @unchecked Sendable {
        private let lock = NSLock()
        private var stopped = false

        var isStopped: Bool {
            lock.lock()
            defer { lock.unlock() }
            return stopped
        }

        func stop() {
            lock.lock()
            stopped = true
            lock.unlock()
        }
    }

    private let stopSignal = StopSignal()
    private var isStopped: Bool { stopSignal.isStopped }

    /// Retires the engine for good: rounds queued behind an in-flight one never run, and the
    /// round already in flight skips every write it has left — the account-scoped cursor
    /// (`writeState`), the settings themselves and their `<key>.phiSync*` sidecars
    /// (`writeSettings` / `snapshotLocalSettings`).
    ///
    /// The exact guarantee, because `shutdown()` is genuinely concurrent with the round (it runs
    /// on the main actor at sign-out while the round runs on the actor's executor): the flag is
    /// read immediately before each of those writes, not only at the round's entry, so what a
    /// shutdown landing at the worst possible moment can still miss is one flag read rather than
    /// a whole round. Concretely, two things may still happen after `shutdown()` returns — a
    /// round that had just passed one of those checks completes that single write, and a commit
    /// already encrypted and handed to the transport still reaches the server (nothing it
    /// answers is persisted; the post-commit writes are checked again). Neither is harmful: at
    /// the instant `shutdown()` returns the account being torn down is still the mounted one, so
    /// those bytes are its own, and the sidecars are not account-scoped in the first place. What
    /// the guarantee rules out is the thing that matters — a round resuming *after* the next
    /// account has mounted and claiming its cursor or its settings.
    ///
    /// Idempotent, and deliberately not reversible — a new sign-in builds a new engine.
    nonisolated func shutdown() {
        stopSignal.stop()
        // Backfill shares engine lifetime (section 8.2 / Task 10). Its lock-protected retirement
        // flag supports synchronous stop; main-thread sign-out cannot wait for an actor hop.
        faviconBackfill?.stop()
    }

    /// Single-use result mailbox (section 4.3). A class, rather than inout, can cross the Task
    /// boundary.
    final class PreviewBox {
        var result: Result<[PhiAccountSpaceSummary], PhiSpacePreviewError>?
    }

    /// What one queued round does. An enum rather than a closure so the body stays
    /// actor-isolated and needs no `@Sendable` gymnastics.
    private enum Round {
        case pull
        case push
        case localChange
        case localSpaceChange
        /// The Space gate's shut <-> open edge. Queued like every other round rather than
        /// applied in place, so it can never land *inside* a round that is parked in
        /// `getUpdates` — see `setSpaceSyncEnabled`.
        case spaceGate(Bool)
        /// §5.3: EVERY Space intent the main-thread facade delivers is a round.
        /// Running one "in place on the engine actor" is not exclusion — the
        /// engine is a reentrant actor, and the two long Space writers
        /// (`pull`'s apply section and `pushSpaces`) each hold one table copy
        /// across a main-actor hop or a whole network round trip and blind-write
        /// it back. An intent that lands inside either window is silently
        /// overwritten, which for `recordLocalDeletion` means the tombstone is
        /// never committed and the Space is later resurrected from a peer's
        /// entity. The queue is the only thing that makes the single writer real.
        case retentionSweep
        case recordLocalDeletion(String)
        /// Local owned-kind change (M3-3 section 5.7), identified by registry label rather than one
        /// case per kind. Owned deletion originates in the section 4.7 diff, not deletion hooks
        /// (R-M3-3-5). Any future bookmark/pin deletion hook must enqueue a Round: an ordinary
        /// actor call could interleave at suspension and lose pendingDelete to a stale round write
        /// (M3-2 section 5.3).
        case localOwnedChange(String)
        /// Read-only account preview for pairing (R-D6-1), serialized on the same queue so it
        /// cannot interleave with settings sync.
        case preview(PreviewBox)
    }

    init(domainKeys: any PhiDomainKeyProviding,
         client: PhiSyncProtocolClient,
         defaults: UserDefaults,
         deviceKeyId: String,
         settings: [SyncableSetting] = SyncableSettings.all,
         spaceAccess: (any PhiSpaceLocalAccess)? = nil,
         spaceStore: (any PhiSpaceSyncStateStore)? = nil,
         markerStore: (any PhiSyncMarkerStore)? = nil,
         ownedKinds: [OwnedKindRegistration] = [],
         faviconBackfill: PhiFaviconBackfillQueue? = nil,
         previewMaxPages: Int = PhiSyncEngine.defaultPreviewMaxPages,
         now: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.domainKeys = domainKeys
        self.client = client
        self.defaults = defaults
        self.deviceKeyId = deviceKeyId
        self.settings = settings
        self.spaceAccess = spaceAccess
        self.spaceStore = spaceStore
        self.ownedKinds = ownedKinds
        self.faviconBackfill = faviconBackfill
        self.previewMaxPages = previewMaxPages
        self.now = now
        // An absent key is `maxSeen = 0`, which makes the first `hlcNow()` the wall clock. A
        // wiped clock (account switch, clean install) re-learns from the first pull before any
        // commit, because `push` is pull-before-commit.
        self.hlcClock = PhiHybridClock(
            maxSeen: (defaults.object(forKey: Self.hlcMaxStateKey) as? NSNumber)?.int64Value ?? 0)
        // Nil selects the two legacy-key fallback, not an in-memory store or a second engine
        // branch. Initialize the mirror before any round runs.
        let resolvedMarkerStore: any PhiSyncMarkerStore =
            markerStore ?? DefaultsBackedPhiSyncMarkerStore(defaults: defaults)
        self.markerStore = resolvedMarkerStore
        self.markerState = resolvedMarkerStore.load()
        self.spaceSectionEnabled = spaceStore?.load().spaceSectionEnabled ?? false
    }

    // MARK: - Public surface

    /// GetUpdates -> decrypt -> merge -> apply, then publish anything the merge left the
    /// server behind on. Never throws: a failed round is logged and retried by the scheduler.
    func pullOnce() async {
        await serialized(.pull)
    }

    /// GetUpdates -> merge -> snapshot -> Commit, with one pull-and-retry on CONFLICT.
    func pushLocalSettings() async {
        await serialized(.push)
    }

    /// Entry point for the debounced `UserDefaults.didChangeNotification` observer.
    func handleLocalDefaultsChange() async {
        await serialized(.localChange)
    }

    /// The Space section's gate (§3.5): account bound AND ARK unlocked AND the join-time
    /// pairing is finished. Driven by the coordinator, NOT by `needsPairing` — §3.6's
    /// auto-create makes that predicate flip true for a moment every time the account gains a
    /// profile, and hanging the gate on it would drop the shared marker and replay the whole
    /// data type each time.
    ///
    /// Queued through `serialized(_:)`, and that is not a detail: the engine is a reentrant
    /// actor, so a gate open awaited from the coordinator while a round is parked in
    /// `getUpdates` would otherwise land in the middle of that round — after it read the Space
    /// table and before it writes anything back — and the round would carry on with a stale
    /// `spaceLive` and re-establish the very marker this edge just dropped. Running it as a
    /// round means the edge happens strictly between rounds: the replay it arms is the next
    /// round's to perform.
    ///
    /// Must therefore be called from *outside* a round (the coordinator is the only caller);
    /// calling it from inside one would wait on the queue that round is holding. A redundant
    /// call is a no-op at the edge check inside the round, but it still queues behind whatever
    /// is in flight, so the coordinator should keep driving it on real state changes only.
    func setSpaceSyncEnabled(_ enabled: Bool) async {
        guard spaceStore != nil else { return }
        await serialized(.spaceGate(enabled))
    }

    /// Read-only Account-column preview for pairing step 2 (R-D6-1). It persists nothing: no
    /// marker/birthday, cursor/baseline, unreadable tags, replay/drain flags, mappings or commits.
    /// It returns before Space counters/outcome logging, avoiding a misleading all-zero Space round
    /// and extra actor hops.
    /// This is the sole Space-shaped read allowed with spaceSectionEnabled closed because it writes
    /// nothing. Results are transient UI data. Opening the gate still clears the marker and replays
    /// the full type through the normal landing path.
    func previewAccountSpaces() async -> Result<[PhiAccountSpaceSummary], PhiSpacePreviewError> {
        let box = PreviewBox()
        await serialized(.preview(box))
        return box.result ?? .failure(.retired)
    }

    /// Section 4.5 deadline, enforced inside runPreview as well as in the wizard. serialized(_:)
    /// creates an unstructured nonthrowing Task: caller cancellation neither stops it nor unblocks
    /// awaiting its value. Without an engine deadline, repeated 60-second requests could monopolize
    /// the round queue and delay settings sync.
    /// The wizard's matching deadline keeps the UI responsive; this one stops further work. With
    /// the 400-page cap, 120 seconds balances large-account enumeration against queue occupancy,
    /// and the loading UI communicates the wait.
    static let previewDeadlineMs: Int64 = 120_000

    /// The gate edge itself. Runs as a queued round; never call it directly.
    private func applySpaceGate(_ enabled: Bool) {
        guard enabled != spaceSectionEnabled else { return }
        spaceSectionEnabled = enabled
        guard mutateSpaceTable({ $0.spaceSectionEnabled = enabled }) else {
            roundOutcome = .cursorSaveFailed
            return
        }
        guard enabled else { return }
        if !armSpaceReplayIfNeeded() { roundOutcome = .cursorSaveFailed }
    }

    /// The replay half of a gate opening, marker first (R-M3-4a-89 / ruling 3), shared with the
    /// entry of every live pull so a failed attempt is retried from the persisted latch rather
    /// than lost.
    ///
    /// Two triggers, one action. `markerMovedWhileGateShut` covers every shut episode this build
    /// observed. `!hasDrainedFullReplay` (with no drain in progress) covers the one it could not
    /// observe: the M3-1 -> M3-2 UPGRADE, where the device already holds a non-nil
    /// `phi.sync.marker` from months of settings sync, an empty `sync.phiSpaces` (so
    /// `hadRecords == false` and guard 2's second trigger is disabled too), and no flag was ever
    /// set because the flag did not exist. Without this disjunct nothing ever drops that marker:
    /// the pull never sees `storedMarker == nil`, so `drainInProgress` is never armed,
    /// `hasDrainedFullReplay` stays false forever, `pushSpaces` returns at its own guard, and the
    /// device silently never publishes a single Space. Idempotent: once a drain completes, only a
    /// real shut episode re-arms it.
    ///
    /// Both kinds share ONE progress marker for data type 2000, so every Space entity the
    /// settings pulls walked past while the gate was shut will never be delivered again. Replay
    /// the type, and re-arm guard 1 so nothing is committed until the replay finishes.
    ///
    /// Order matters because `marker.json` and the Space plist cannot commit atomically: the
    /// nil marker is persisted FIRST; only after that write is acknowledged is the latch consumed
    /// and the drain armed. A failed marker write leaves the latch standing and the old marker on
    /// disk, which is a safe, retryable state. The opposite order — consume the latch, then fail
    /// the marker write — would let the next incremental pull stamp `hasDrainedFullReplay` over a
    /// gap, and the entities the gap covered would never be delivered.
    ///
    /// Returns false only when a durable write failed; the write helper already counted it.
    @discardableResult
    private func armSpaceReplayIfNeeded() -> Bool {
        let table = loadSpaceTable()
        guard table.markerMovedWhileGateShut || (!table.hasDrainedFullReplay && !table.drainInProgress) else {
            return true
        }
        AppLogInfo("[phi-sync] space gate open (marker_moved=\(table.markerMovedWhileGateShut) drained=\(table.hasDrainedFullReplay)); replaying data type \(PhiSyncEntity.dataTypeID)")
        // Re-clearing an already nil marker is a no-write success.
        guard persistStoredMarker(nil) else { return false }
        // Deliberately untouched: reconciled / server / entityId / version / hidden /
        // deletedAtMs / purgedAtMs. The ACCOUNT did not change; clearing them would
        // re-arm the wholesale adopt and silently drop local edits that were just
        // stamped.
        return mutateSpaceTable { table in
            table.markerMovedWhileGateShut = false
            table.hasDrainedFullReplay = false
            table.drainInProgress = true
        }
    }

    /// Entry point for the debounced `spacesPublisher()` / `.spaceThemeDidChange` observers
    /// (§5.4). Same shape as `handleLocalDefaultsChange()`.
    func handleLocalSpacesChange() async {
        await serialized(.localSpaceChange)
    }

    /// Entry point for the debounced `bookmarkChangesPublisher()` /
    /// `pinnedTabChangesPublisher()` observers (§5.7). Same shape as
    /// `handleLocalSpacesChange()`, one line down to `serialized`.
    ///
    /// `label` is a registration's `label` — the unique key of the owned-kind list — and it
    /// travels no further than the round's log line: the publish section walks the whole
    /// registration list, so one kind's local change is an ordinary push round. It is a
    /// parameter rather than two methods because **kind is data, not code** (`Round`'s own
    /// `localOwnedChange` comment).
    ///
    /// Must be called from *outside* a round, like every other driver here: it waits on the
    /// queue the round in flight is holding.
    func handleLocalOwnedChange(label: String) async {
        await serialized(.localOwnedChange(label))
    }

    /// Delivered by PhiSpaceSyncState.shared as a queued round, preserving the single writer
    /// required by section 5.3. Actor isolation alone is insufficient: pull and pushSpaces hold
    /// table copies across network/main-actor suspensions. An interleaved deletion would be
    /// overwritten, permanently losing pendingDelete and allowing the next incoming entity to
    /// recreate the Space. Call only from outside a round, like setSpaceSyncEnabled.
    func recordLocalDeletion(spaceId: String) async {
        await serialized(.recordLocalDeletion(spaceId))
    }

    func runRetentionSweep() async {
        await serialized(.retentionSweep)
    }

    /// §9.2's 30-day sweep over expired soft deletes. Runs as a queued round
    /// (`case .retentionSweep`); never call it directly.
    ///
    /// Two phases, and the split is the point. `purgeExpired` trims the table
    /// and is persisted BEFORE any `await`; only then does the data cascade run.
    ///
    /// The straight version -- load the table, trim it, `await spaceAccess.purge`
    /// in a loop, write the trimmed copy back -- is a lost update: every `purge`
    /// is a main-actor hop, i.e. an actor suspension point, and the round queued
    /// behind it does its own read-modify-write of the same table. The final
    /// `writeSpaceTable` would then put back a snapshot taken before that round
    /// existed. This is exactly what §5.3's single-writer rule is for, so the
    /// sweep runs as a round AND keeps no stale copy across a suspension.
    private func applyRetentionSweep() async {
        await applySpaceRetentionSweep()
        // Drop expired tombstone cursors before the cascade (section 3.6), so the same expired
        // record is not classified by both passes.
        await dropExpiredOwnedTombstones()
        // Recompute the idempotent cursor cascade on every retention round (section 9.3),
        // regardless of newly purged Spaces. purgeExpired marks purgedAtMs durably in phase 1 and
        // never returns that UUID again; tying the cascade only to that result would permanently
        // orphan cursors after a file-save failure. Section 11.4 does not retry such saves.
        await applyOwnedRetentionCascade()
        await purgeExpiredSoftDeletedOwnedRows()
    }

    /// Second soft-delete exit (section 5.7), after the cursor cascade in the same retention round.
    /// Cursor expiry reads deletedAtMs; row expiry reads deletedDate in a different store. Neither
    /// substitutes for the other: permanently unpublished tombstones may already have lost their
    /// cursors.
    private func purgeExpiredSoftDeletedOwnedRows() async {
        let cutoff = Date(timeIntervalSince1970:
                            Double(now() - PhiSpaceSyncState.retentionMs) / 1000)
        for registration in ownedKinds {
            guard !isStopped else { return }
            guard let purge = registration.purgeSoftDeletedRows else { continue }
            let purged = await purge(cutoff)
            // R12: log only kind and count.
            if purged > 0 {
                AppLogInfo("[phi-sync] purged soft-deleted rows "
                           + "kind=\(registration.label) count=\(purged)")
            }
        }
    }

    /// Space-side retention: purgeExpired followed by the local data cascade.
    private func applySpaceRetentionSweep() async {
        guard let spaceAccess, spaceStore != nil else { return }
        var table = loadSpaceTable()
        let expired = table.purgeExpired(nowMs: now())
        guard !expired.isEmpty else { return }
        // Phase 1: persist the trimmed table with no suspension in between. The
        // cursors are now permanent tombstones -- §9.1's two promises (a
        // replayed tombstone is a no-op, snapshot never resurrects the uuid)
        // rest on the cursor being there with a `deletedAtMs`, so they hold even
        // if the cascade below is interrupted.
        writeSpaceTable(table)

        // Phase 2: cascade the data. No table copy is held across these awaits.
        for uuid in expired {
            guard !isStopped else { return }
            // D6: purgeExpired returns syncUuid, while purge accepts a local ID. Unresolved means
            // no local row to remove; phase 1 already persisted the tombstone cursor.
            guard let local = await spaceAccess.localSpaceId(forSyncUuid: uuid) else { continue }
            do {
                try await spaceAccess.purge(spaceId: local)
                // Remove the mapping only after purge succeeds. Keep the permanent tombstone cursor
                // keyed by syncUuid.
                await spaceAccess.dropSpaceMapping(forSpaceId: local)
            } catch {
                // Keep the mapping if the cascade fails; log only sanitized metadata (R12).
                // currentSpaces reads remaining local rows without hiddenSpaceIds filtering.
                // Dropping the mapping would let lazy minting publish a fresh UUID, resurrecting a
                // Space that phase 1 will never purge again. Retaining the mapping preserves the
                // tombstoned cursor and snapshot eligibility exclusion.
                AppLogWarn("[phi-sync] retention purge failed; keeping the mapping so the row cannot be republished (\(PhiSyncLog.describe(error)))")
            }
        }
    }

    /// Drop owned tombstone cursors finalized at least 30 days ago (section 3.6). PhiOwnedItemTable
    /// documents safety: the server only returns the latest version per entity ID, so future
    /// delivery is either the same tombstone or a newer resurrection, with the same result even
    /// without the cursor.
    /// Run only in retentionSweep, alongside Space expiry. Local read failure does not affect the
    /// cursor-only deletedAtMs/now criterion; beginOwnedRound loads cursor tables before attempting
    /// local reads.
    private func dropExpiredOwnedTombstones() async {
        // Use the common owned-item gate. While closed, no expired cursor work can have
        // accumulated, so avoid the otherwise wasted bookmark/pin reads. Expiry depends only on
        // deletedAtMs and now; the next sweep after reopening still removes eligible cursors.
        guard spaceSectionEnabled, !ownedKinds.isEmpty, spaceStore != nil else { return }
        await beginOwnedRound()
        let nowMs = now()
        for registration in ownedKinds {
            guard !isStopped else { return }
            var table = ownedTables[registration.label] ?? PhiOwnedItemTable()
            let before = table.cursors.count
            table.dropExpiredTombstones(nowMs: nowMs)
            let dropped = before - table.cursors.count
            guard dropped > 0 else { continue }
            // R12: log only kind and count.
            AppLogInfo("[phi-sync] expired tombstone cursors dropped "
                       + "kind=\(registration.label) dropped=\(dropped)")
            writeOwnedTable(registration, table)
        }
    }

    /// Idempotent retention cascade for owned cursors after a Space's 30-day purge (section 9.3,
    /// E11/A12). Delete only if (a) cursor.ownerUuid names a purged Space and (b) no live local row
    /// claims the identity. Otherwise orphaned baselines would look like local deletions and
    /// publish tombstones for account entities still needed elsewhere.
    /// Condition (b) prevents deleting live-row cursors when ownerUuid lags behind gated, undrained
    /// or scope-mismatched local state. Losing such a cursor would permit a baseVersion-zero create
    /// to overwrite the account row. Retain and rehome live claims instead. Read ownerUuid,
    /// refreshed by the snapshot pre-pass, rather than decoding potentially stale reconciled
    /// baselines (N3/I9/R-exec-8).
    private func applyOwnedRetentionCascade() async {
        // Use the same gate. Closed-gate candidates are empty: condition (a) requires purgedAtMs,
        // and the Space sweep cannot purge without spaceAccess.
        guard spaceSectionEnabled, !ownedKinds.isEmpty, spaceStore != nil else { return }
        // Share the round-start local/table read, which records ownedReadFailed per kind and runs
        // at most once per round.
        await beginOwnedRound()
        let spaceTable = loadSpaceTable()
        let maps = await ownedRoundMaps()
        for registration in ownedKinds {
            guard !isStopped else { return }
            guard !ownedReadFailed.contains(registration.label) else { continue }
            var table = ownedTables[registration.label] ?? PhiOwnedItemTable()
            // Condition (a) excludes nil ownerUuid: those cursors either never had resolvable local
            // rows or have not yet had an owner refreshed. Neither points to a purged Space.
            let candidates = Set(table.cursors.compactMap { identity, cursor -> String? in
                guard let owner = cursor.ownerUuid,
                      spaceTable.cursors[owner]?.purgedAtMs != nil else { return nil }
                return identity
            })
            guard !candidates.isEmpty else { continue }
            let live: OwnedLiveRows
            do {
                live = try await registration.liveOwners(candidates, maps)
            } catch {
                // A failed read skips this kind's cascade for this round. The next sweep recomputes
                // all criteria without one-shot state.
                AppLogWarn("[phi-sync] retention cascade skipped kind=\(registration.label): "
                           + "the local rows could not be read (\(PhiSyncLog.describe(error)))")
                continue
            }
            // Track changes in local counters, not the existing counters.rehomedCursors value,
            // which publication may already have changed in this round and would cause an
            // unnecessary save.
            var dropped = 0
            var rehomed = 0
            var parked = 0
            for identity in candidates.sorted() {
                // Apply the parked-payload exemption before condition (b) (R-M3-4a-27). A parked
                // retarget retains the old owner; purging that Space can remove its row. Deleting
                // the cursor would then lose pendingApply and harvested identity after the shared
                // marker passed the page, so the retarget would never replay. Keep the cursor:
                // R-M3-4a-42(a) recreates a missing row from the payload. Do not guess a new owner
                // when no live row remains.
                if table.cursors[identity]?.pendingApply != nil {
                    parked += 1
                    continue
                }
                guard live.claimed.contains(identity) else {
                    table.cursors.removeValue(forKey: identity)
                    dropped += 1
                    continue
                }
                // A live claim fails condition (b), so keep it. If its current owner is unresolved,
                // retain the last known owner and retry next sweep rather than inventing an owner
                // that would mislead the tombstone diff.
                guard let current = live.owners[identity],
                      table.cursors[identity]?.ownerUuid != current else { continue }
                table.cursors[identity]?.ownerUuid = current
                rehomed += 1
            }
            var counters = ownedCounters[registration.label] ?? OwnedRoundCounters()
            counters.rehomedCursors += rehomed
            ownedCounters[registration.label] = counters
            if parked > 0 {
                AppLogInfo("[phi-sync] retention cascade kept parked cursors "
                           + "kind=\(registration.label) parked=\(parked)")
            }
            guard dropped > 0 || rehomed > 0 else { continue }
            // R12: kind/count only. Always write through writeOwnedTable, which enforces retirement
            // and maintains per-kind flags; never call store.save directly.
            AppLogInfo("[phi-sync] retention cascade kind=\(registration.label) "
                       + "dropped=\(dropped) rehomed=\(rehomed)")
            writeOwnedTable(registration, table)
        }
    }

    /// Drops every account-scoped cursor, `hasAdopted` included, so the next account's entity
    /// is adopted rather than merged against the previous account's timestamps. As of M3-4a
    /// that is the five `stateKeys` *and* the marker file: the marker and the birthday live in
    /// `marker.json` (§2.10), and "every account-scoped cursor" has to stay true, so the file
    /// is deleted here — deleted, not saved empty, the same contract as the self-revocation.
    ///
    /// **Test and recovery helper — the app never calls this.** The account-scope reset that
    /// actually ships runs one layer up, in
    /// `PhiChromiumCoordinator.resetPhiSyncCursorIfAccountChanged(accountId:defaults:)`: it
    /// wipes the same `stateKeys` from outside, keyed on a recorded owner account, at the one
    /// moment the wipe is safe — before the engine for the new account exists (the marker file
    /// needs no wipe there: it is inside the account directory). Doing it from in here cannot
    /// cover that case anyway: sign-out calls `shutdown()`, and the guard below then makes
    /// this a no-op, precisely because a retired engine's `UserDefaults` may already belong to
    /// the account mounted next.
    ///
    /// **Account scope only.** Nothing that happens *within* one account may call this:
    /// clearing `hasAdopted` re-arms the wholesale adopt in `apply`, and the account's own
    /// settings history is precisely what makes a field-level merge possible. The two
    /// same-account recoveries (a server row this device can no longer address, and a store
    /// birthday that no longer matches) go through `clearRemoteCursor()` and
    /// `resetForNewStoreBirthday()` instead.
    ///
    /// Deliberately synchronous and *not* queued: it runs to completion between the suspension
    /// points of any round, so it never tears a half-written cursor.
    func resetSyncState() {
        guard !isStopped else { return }
        canPublishThisRound = false
        for key in Self.stateKeys { defaults.removeObject(forKey: key) }
        // `hlcMaxStateKey` is one of them, so drop the in-memory mirror too. Logical time is
        // per account, and the first pull of the next account re-learns it before any commit.
        hlcClock = PhiHybridClock()
        // Marker/birthday live in the account's marker.json, outside stateKeys (section 2.10).
        // Resetting all account cursors must delete that file and reset its mirror, not save an
        // empty table (section 4.4).
        markerState = PhiSyncMarkerFile()
        markerStore.deleteFile()
    }

    // MARK: - Round serialization

    /// Runs `round` after every round enqueued before it. Actor reentrancy means a round that
    /// is parked in `getUpdates` or `commit` would otherwise let the next one in and both would
    /// interleave their writes to `storedVersion` / `storedMarker` / `storedLastEntity`.
    private func serialized(_ round: Round) async {
        let previous = roundQueue
        let task = Task { [previous] in
            await previous?.value
            await self.run(round)
        }
        roundQueue = task
        await task.value
    }

    private func run(_ round: Round) async {
        // A round enqueued before sign-out but still waiting behind an in-flight one must not
        // start against the account that has since been mounted on the same defaults.
        guard !isStopped else { return }
        // §11's counters are per ROUND, not per pull: one round can contain a
        // NOT_MY_BIRTHDAY retry, the push's preflight pull and a scoped conflict
        // retry, and `pushSpaces` runs after the pull's tail has already finished.
        spaceCounters = SpaceRoundCounters()
        canPublishThisRound = false
        // Owned counters, local-read results and learned tag indices are per-round, not per-pull.
        ownedCounters = [:]
        ownedReadFailed = []
        ownedTagIndices = [:]
        ownedRoundStarted = []
        ownedLossObservedAtEntry = []
        ownedParkedRetryDone = []
        ownedMapsThisRound = nil
        // Reset B-2 round counters here (sections 2.5/2.8); pulls within a round accumulate them.
        cursorSaveFailures = 0
        roundOutcome = .ok
        roundPages = 0
        roundMarkerAdvanced = false
        ownedTables = [:]
        ownedMustRepublish = [:]
        // Reset only this round's favicon collection (section 8.2 / Task 10). The queue retains
        // prior candidates that have not yet been processed.
        faviconCandidatesThisRound = []
        faviconPinCandidatesThisRound = []
        ownedDeferredOwners = [:]
        // Same reason, same scope: the NOT_MY_BIRTHDAY recursion (:608), the push's initial
        // pull (:1160 / :1456) and the CONFLICT retry (:1250) are all pulls inside ONE round,
        // and none of them re-lists the account's profiles.
        didRefreshProfilesThisRound = false
        switch round {
        case .pull:
            _ = await pull(retryOnBirthday: true, thenPush: true)
        case .push:
            await push(retryOnConflict: true)
        case .localChange:
            guard !isApplyingRemote else { return }
            // R2.2: stamp the sidecars BEFORE `push`'s pull gate, so a preference changed
            // offline carries its own edit time rather than the reconnect time. `pushSettings`
            // runs `snapshotLocalSettings()` again and reuses the stored stamp for a key that
            // has not changed since, so the edit time survives to the wire.
            //
            // Only once this device has settings history. With no sidecars `snapshot` treats
            // EVERY registered key as locally changed and stamps them all, which is exactly the
            // wholesale-publication failure `hasAdopted` documents; before adoption the
            // stamping stays where it was, inside the pull-gated push.
            if hasAdopted { _ = snapshotLocalSettings() }
            await push(retryOnConflict: true)
        case .localSpaceChange:
            guard !isApplyingRemote else { return }
            await push(retryOnConflict: true)
        case .spaceGate(let enabled):
            applySpaceGate(enabled)
        case .retentionSweep:
            await applyRetentionSweep()
        case .recordLocalDeletion(let localSpaceId):
            // Translate the local SpaceManager ID to the cursor's syncUuid at this boundary
            // (section 3.4). No mapping means never published and hence no tombstone to send,
            // matching recordLocalDeletion's entityId guard. The PhiSpaceSyncState facade still
            // accepts local IDs.
            if let uuid = await spaceAccess?.syncUuid(forSpaceId: localSpaceId) {
                runSpaceIntent { table in table.recordLocalDeletion(spaceId: uuid) }
            } else {
                AppLogInfo("[phi-sync] a local Space delete has no account identity; nothing to tombstone")
            }
        case .localOwnedChange(let label):
            // Suppress echoes as for localSpaceChange. The label is diagnostic only: publication
            // visits every registered kind, so any owned-kind change schedules an ordinary push
            // round.
            guard !isApplyingRemote else { return }
            AppLogInfo("[phi-sync] local change for owned kind=\(label)")
            await push(retryOnConflict: true)
        case .preview(let box):
            await runPreview(into: box)
            return          // Preview is not a Space round: emit neither §11 counters nor an outcome.
        }
        logRoundOutcome()
        await logSpaceRound()
        logOwnedRounds()
        await runFaviconBackfill()
    }

    /// Emit the B-2 outcome here (sections 2.8/13.2), not in the queue-only serialized wrapper.
    /// Unlike Space/owned counters, this must run for closed gates and settings-only engines.
    /// Precedence: preserve notMyBirthday; any cursor save failure wins next; otherwise local read
    /// failure replaces ok; otherwise a present-but-disabled Space store yields gated (no Space
    /// store is a normal settings-only engine, RR-B10). R12 permits only enum names, counts and
    /// booleans.
    private func logRoundOutcome() {
        var outcome = roundOutcome
        if outcome != .notMyBirthday {
            if cursorSaveFailures > 0 {
                outcome = .cursorSaveFailed
            } else if outcome == .ok, !ownedReadFailed.isEmpty {
                outcome = .localReadFailed
            } else if outcome == .ok, spaceStore != nil, !spaceSectionEnabled {
                outcome = .gated
            }
        }
        lastLoggedRound = LoggedRound(outcome: outcome, pages: roundPages,
                                      markerAdvanced: roundMarkerAdvanced,
                                      cursorSaveFailures: cursorSaveFailures)
        AppLogInfo("[phi-sync] round outcome=\(outcome.rawValue) pages=\(roundPages) "
                   + "marker_advanced=\(roundMarkerAdvanced) cursor_save_failed=\(cursorSaveFailures)")
    }

    /// Run favicon backfill after finalizing round counters (section 8.2 / Task 10). It does not
    /// affect sync cursors, baselines or publication, so failures do not alter sync counts. The
    /// queue processes up to 20 per round and retains overflow; drain it again even when the next
    /// round adds no candidates.
    private func runFaviconBackfill() async {
        guard let queue = faviconBackfill, !isStopped else { return }
        let rows = faviconCandidatesThisRound
        let pins = faviconPinCandidatesThisRound
        faviconCandidatesThisRound = []
        faviconPinCandidatesThisRound = []
        if !rows.isEmpty { await queue.enqueue(rows) }
        if !pins.isEmpty { await queue.enqueue(pins) }
        _ = await queue.drainOnce()
    }

    // MARK: - Read-only pairing account preview (section 4)

    /// Section 4.3 round body, serialized on the engine's round queue. Never call directly.
    private func runPreview(into box: PreviewBox) async {
        let startedAt = now()
        // Reset latest-preview statistics before early failures. Every exit records this preview's
        // counts, including zero when startup fails, so diagnostics never reuse an earlier
        // preview's pagination totals.
        lastPreviewStats = (0, 0)
        guard !isStopped else { box.result = .failure(.retired); return }
        let key: SymmetricKey
        do {
            key = try await domainKeys.domainKey()
        } catch {
            AppLogWarn("[phi-sync] space preview failed: domain key unavailable (\(PhiSyncLog.describe(error)))")
            box.result = .failure(.transport("domain_key"))
            return
        }
        guard !isStopped else { box.result = .failure(.retired); return }

        var summaries: [String: (entity: Phi_PhiSpaceEntity, version: Int64)] = [:]
        var pages = 0
        var entities = 0
        var refused = 0
        var unreadable = 0
        // Local marker only; never persist response marker or birthday. An empty storedBirthday is
        // valid before initial settings sync completes; the server supplies one and the preview
        // still does not write it back.
        var marker: Data?
        var more = true
        do {
            // Use the independent preview budget. The normal 64 x 500 pull cap includes all entity
            // kinds and tombstones, which can exhaust it before enumerating an ordinary account's
            // Spaces (section 5.8).
            while more, pages < previewMaxPages {
                // Check the engine deadline before requesting the next page (section 4.5). An
                // in-flight request may still take its URLSession timeout, but no further page
                // starts, releasing the round queue afterwards.
                guard now() - startedAt < Self.previewDeadlineMs else {
                    lastPreviewStats = (pages, entities)
                    AppLogWarn("[phi-sync] space preview: pages=\(pages) entities=\(entities) "
                               + "error=deadline")
                    box.result = .failure(.timedOut)
                    return
                }
                let response = try await client.getUpdates(marker: marker, storeBirthday: storedBirthday)
                guard !isStopped else {
                    lastPreviewStats = (pages, entities)
                    box.result = .failure(.retired)
                    return
                }
                marker = response.newMarker
                pages += 1
                more = response.changesRemaining
                for entity in response.entities {
                    entities += 1
                    // Ignore settings entities and tombstones; deleted account Spaces must not
                    // appear as pairing choices.
                    guard entity.clientTagHash != PhiSyncEntity.settingsClientTagHash,
                          !entity.deleted else { continue }
                    guard let decoded = try? PhiEntityCodec.decrypt(entity.ciphertext, key: key) else {
                        unreadable += 1     // Count only; do not add to `unreadableTagHashes`.
                        continue
                    }
                    guard case .space(let space)? = decoded.kind else { continue }
                    let expected = PhiSyncEntity.clientTagHash(
                        for: PhiSyncEntity.spaceClientTag(space.spaceUuid))
                    guard expected == entity.clientTagHash else { unreadable += 1; continue }
                    // Reject both agent-pattern payload variants. D1 fixes the default Space
                    // identity, which must never be selectable for pairing.
                    guard !SyncableSpaces.refuses(space) else { refused += 1; continue }
                    guard space.spaceUuid != SyncableSpaces.defaultSpaceUuid else { continue }
                    // Full replay normally delivers each entity once; defensively retain the
                    // highest version when duplicates occur.
                    if let seen = summaries[space.spaceUuid], seen.version >= entity.version { continue }
                    summaries[space.spaceUuid] = (space, entity.version)
                }
            }
        } catch PhiSyncProtocolError.notMyBirthday {
            // Preview does not repair cursors; regular pull owns that work. Its normal
            // settings-sync birthday retry can repair storedBirthday so a later preview retry
            // succeeds.
            lastPreviewStats = (pages, entities)
            AppLogWarn("[phi-sync] space preview: pages=\(pages) entities=\(entities) "
                       + "error=not_my_birthday")
            box.result = .failure(.transport("not_my_birthday"))
            return
        } catch {
            lastPreviewStats = (pages, entities)
            AppLogWarn("[phi-sync] space preview: pages=\(pages) entities=\(entities) "
                       + "error=\(PhiSyncLog.describe(error))")
            box.result = .failure(.transport(PhiSyncLog.describe(error)))
            return
        }

        guard !more else {
            // Never return partial choices: missing an existing account Space could make the user
            // select Add as new and mint a duplicate. Record counts through lastPreviewStats;
            // truncated remains a payload-free error.
            lastPreviewStats = (pages, entities)
            AppLogWarn("[phi-sync] space preview: pages=\(pages) entities=\(entities) "
                       + "error=truncated")
            box.result = .failure(.truncated)
            return
        }

        let out = summaries.values.map { item -> PhiAccountSpaceSummary in
            let entity = item.entity
            return PhiAccountSpaceSummary(
                syncUuid: entity.spaceUuid,
                name: entity.name.stringValue,
                iconName: entity.iconName.stringValue,
                colorHex: entity.colorHex.stringValue,
                profileUuid: entity.profileUuid.stringValue,
                isDefault: false,
                themeId: entity.themeID.stringValue,
                overlayOpacityLightMilli: entity.overlayOpacityLight.intValue,
                overlayOpacityDarkMilli: entity.overlayOpacityDark.intValue)
        }.sorted { $0.syncUuid < $1.syncUuid }   // Deterministic order for tests and two-device comparisons.
        lastPreviewStats = (pages, entities)
        // Section 9.1(1); R12 allows counts only.
        AppLogInfo("[phi-sync] space preview: pages=\(pages) entities=\(entities) "
                   + "spaces=\(out.count) refused=\(refused) unreadable=\(unreadable) "
                   + "ms=\(now() - startedAt)")
        box.result = .success(out)
    }

    // MARK: - §11 round counters

    /// §11's one-line-per-round counter set. Metadata only (R12): counts and
    /// booleans, never a uuid, a name, an icon or a colour.
    ///
    /// `applied` counts entities that LANDED this round (creates, field updates,
    /// rebinds and remote soft deletes); `tombstones` counts the tombstones this
    /// device PUBLISHED, next to `pushed` and `conflicts`.
    private struct SpaceRoundCounters {
        var pulled = 0
        var applied = 0
        var refused = 0
        var pushed = 0
        var tombstones = 0
        var conflicts = 0
        var profilesCreated = 0
        /// ok | failed | skipped. `skipped` covers "already refreshed this
        /// round", "inside the 30 s interval" and "the gate is shut" -- §11 is
        /// explicit that it is NOT a failure. Filled in by Task 11's refresh hook;
        /// until that lands no refresh runs at all, so `skipped` is the true value.
        var profileRefresh = "skipped"
    }
    private var spaceCounters = SpaceRoundCounters()

    /// One info line per round, at the end of the round.
    private func logSpaceRound() async {
        guard spaceSectionEnabled, spaceStore != nil else { return }
        let table = loadSpaceTable()
        let held = table.cursors.values.filter { $0.heldProfileUuid != nil }.count
        let parked = table.cursors.values.filter { $0.pendingApply != nil }.count
        // Section 9.3: mapped counts explicit mappings, excluding the implicit default-Space
        // constant. Unmapped counts eligible local Spaces lacking mappings; steady state is zero.
        // Persistent nonzero indicates lazy identity minting failures, exposing Spaces that never
        // reached the account. Report counts, not UUIDs (R12). Fetch mappings once because filter
        // cannot await.
        var mapped = 0
        var unmapped = 0
        if let spaceAccess {
            let mappings = await spaceAccess.allSpaceMappings()
            mapped = mappings.count
            unmapped = await spaceAccess.currentSpaces().filter {
                $0.spaceId != LocalStore.defaultSpaceId && mappings[$0.spaceId] == nil
            }.count
        }
        AppLogInfo("""
            [phi-sync] spaces pulled=\(spaceCounters.pulled) applied=\(spaceCounters.applied) \
            held=\(held) parked=\(parked) refused=\(spaceCounters.refused) \
            unreadable=\(table.unreadableTagHashes.count) pushed=\(spaceCounters.pushed) \
            tombstones=\(spaceCounters.tombstones) conflicts=\(spaceCounters.conflicts) \
            drained=\(table.hasDrainedFullReplay) drain_in_progress=\(table.drainInProgress) \
            profiles_created=\(spaceCounters.profilesCreated) \
            profile_refresh=\(spaceCounters.profileRefresh) \
            mapped=\(mapped) unmapped=\(unmapped)
            """)
    }

    // MARK: - Pull

    /// Why a pull could not turn the account's entity into settings. Only `.tombstone` is
    /// healable: the other two mean the server holds real content this build must not
    /// overwrite, and the refusal has to stand until a re-minted key or a newer build can read
    /// it. A tombstone carries nothing to protect, so it may eventually be re-created.
    private enum UnusableReason: String {
        case tombstone
        case foreignPayload = "payload is not settings"
        case undecryptable = "ciphertext could not be opened"
    }

    /// What one pull could make of the account's settings entity.
    private enum RemoteView {
        /// The server sent nothing under our client tag this round.
        case absent
        /// Decrypted settings this device can merge against.
        case usable(Phi_PhiSettingEntity)
        /// The entity is there but this build cannot turn it into settings (a tombstone, a
        /// ciphertext it cannot open, or a payload that is not `.setting`). Its bytes must
        /// survive: this device may not publish over them.
        case unusable(reason: UnusableReason)
    }

    /// Marker suppression is round-level state, not a loop break (R-M3-4a-37). With resetToNil,
    /// advance the in-memory request marker page by page (R-M3-4a-76), suppress all page
    /// persistence, then persist nil at round end. Triggered by guard-2 empty-table replay.
    /// Unusable settings no longer suppress the marker (review A3): see
    /// `UnreadableSettingsRecord`.
    private enum MarkerSuppression { case none, resetToNil }

    /// Review A3. Why the marker must not rewind for an unreadable settings entity: the marker
    /// is shared by every kind on data type 2000, so rewinding it re-downloads the whole type
    /// every round, keeps `drainInProgress` from ever finalizing, and thereby holds Space and
    /// owned-item publication for as long as the entity stays unreadable — which for a foreign
    /// payload or a re-minted key is forever on this build. Instead the refusal is recorded
    /// here, durably, together with what it was refused under. The marker advances normally;
    /// the durable refusal to publish over the entity is `storedLastEntity == nil` with a
    /// non-nil `storedEntityId`, which `pushSettings` already honours. The record is what lets a
    /// later pull re-read the entity exactly when something that could make it readable has
    /// changed: a different domain key, or a newer build.
    struct UnreadableSettingsRecord: Codable, Equatable {
        var reason: String
        var keyFingerprint: Data
        var build: String

        /// A tombstone heals by the round counter, never by a key or build change. Undecryptable
        /// bytes may open under a re-minted key or an envelope version a newer build knows;
        /// a foreign payload only under a newer build.
        func isHealable(keyFingerprint current: Data, build currentBuild: String) -> Bool {
            switch reason {
            case UnusableReason.tombstone.rawValue: return false
            case UnusableReason.undecryptable.rawValue:
                return keyFingerprint != current || build != currentBuild
            default: return build != currentBuild
            }
        }
    }

    /// What identifies "this build" for `UnreadableSettingsRecord`: a newer build is the only
    /// thing that can make a foreign payload readable.
    static let buildIdentity: String = {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? ""
        let build = info?["CFBundleVersion"] as? String ?? ""
        return "\(version)/\(build)"
    }()

    /// The fingerprint `UnreadableSettingsRecord` keys on. Never logged (R12).
    private static func fingerprint(of key: SymmetricKey) -> Data {
        Data(SHA256.hash(data: key.withUnsafeBytes { Data($0) }))
    }

    /// The eight named section 2.8 outcomes describe existing early-return/failure paths, not new
    /// behavior. rawValue is safe for R12 logs.
    enum RoundOutcome: String {
        case ok
        case gated
        case pageBudgetExhausted = "page_budget_exhausted"
        case localReadFailed = "local_read_failed"
        case unusableSettings = "unusable_settings"
        case cursorSaveFailed = "cursor_save_failed"
        case pullFailed = "pull_failed"
        case notMyBirthday = "not_my_birthday"
    }

    /// Named debug abort points (section 12.2 Q-12), keeping preference-key strings and conditional
    /// compilation out of call sites (ruling 8).
    private enum DebugAbortPoint { case afterApply, betweenKinds }

    #if DEBUG || PHI_SYNC_DEBUG_SWITCHES
    static let abortAfterApplyKey = "phi.sync.debug.abortAfterApply"
    static let abortBetweenKindsKey = "phi.sync.debug.abortBetweenKinds"
    #endif

    /// One-shot abort: clear the enabled key before aborting to avoid crashing again on restart.
    /// Release builds have an empty body. PHI_SYNC_DEBUG_SWITCHES is supplied only by
    /// acceptance-build OTHER_SWIFT_FLAGS, not project defaults; DEBUG also enables it (ruling 8).
    private func abortIfRequested(_ point: DebugAbortPoint) {
        #if DEBUG || PHI_SYNC_DEBUG_SWITCHES
        let key: String
        switch point {
        case .afterApply: key = Self.abortAfterApplyKey
        case .betweenKinds: key = Self.abortBetweenKindsKey
        }
        let store = UserDefaults.standard
        guard store.bool(forKey: key) else { return }
        store.removeObject(forKey: key)
        AppLogError("[phi-sync] deliberate abort requested by \(key)")
        abort()
        #endif
    }

    /// Return true only when every page has been downloaded and processed; budget exhaustion cannot
    /// authorize publishing. Under M3-4a B-2 (section 2.4), each page routes, lands
    /// settings/Spaces/owned kinds, writes derived flags, then persists its marker last. Any
    /// cursor/table/mapping/marker failure blocks marker advancement and all publication this
    /// round. Next round idempotently replays from the last fully persisted page (section 2.7).
    private func pull(retryOnBirthday: Bool, thenPush: Bool) async -> Bool {
        canPublishThisRound = false
        guard !isStopped else { return false }
        let key: SymmetricKey
        do {
            key = try await domainKeys.domainKey()
        } catch {
            AppLogWarn("[phi-sync] pull skipped: domain key unavailable (\(PhiSyncLog.describe(error)))")
            return false
        }
        // Sign-out can land in any of this round's suspension points; from here the round is
        // holding the *previous* account's domain key, so everything below is off-limits.
        guard !isStopped else { return false }

        // Review A3: a settings entity refused under an older key or build is re-read by ONE
        // full replay, armed marker-first (R-M3-4a-89) the moment something that could make
        // it readable has changed. Persist the nil marker before forgetting the record, so a
        // failed write leaves both the record and the old marker standing for a retry.
        let keyFingerprint = Self.fingerprint(of: key)
        if let record = unreadableSettingsRecord,
           record.isHealable(keyFingerprint: keyFingerprint, build: Self.buildIdentity) {
            AppLogInfo("[phi-sync] settings entity was unusable (\(record.reason)) under a previous key or build; replaying data type \(PhiSyncEntity.dataTypeID) to re-read it")
            guard persistStoredMarker(nil) else {
                roundOutcome = .cursorSaveFailed
                return false
            }
            unreadableSettingsRecord = nil
        }

        // Guard 1 (§5.5): the drain is a PROCESS, not the property of one pull. It is armed
        // only while the Space section is live — a gated-off pull hands the Space section
        // nothing, so letting it satisfy the guard would let a fresh device publish its
        // factory default Space over the account's.
        //
        // The whole Space side of this round obeys one rule: **no copy of the table spans a
        // suspension point, and every flag is persisted the moment it is observed**. The
        // shared marker is written page by page (`persistStoredMarker(marker)` is the last
        // write of every page), so a flag derived from it has to be persisted page by page
        // too — and BEFORE that page's marker (R-M3-4a-77): a flag written after the marker
        // is simply gone when the marker write succeeds and the flag write does not, with the
        // marker left standing past whatever it walked over.
        let spaceLive = spaceSectionEnabled && spaceStore != nil && spaceAccess != nil
        // A gate opening whose nil-marker write failed left `markerMovedWhileGateShut` standing
        // (review A1). Retry it here, marker first, before anything reads the table: with the
        // latch set the old marker on disk stands past entities this device has never seen.
        if spaceLive, !armSpaceReplayIfNeeded() {
            roundOutcome = .cursorSaveFailed
            return false
        }
        let spaceTableAtEntry = loadSpaceTable()
        if spaceLive, storedMarker == nil, !spaceTableAtEntry.drainInProgress {
            // Persisted immediately, not at the tail: page 1 already makes the marker
            // non-nil, so a round that dies on page 2 would otherwise leave a non-nil marker
            // on disk beside `drainInProgress == false`. This precondition (`storedMarker ==
            // nil`) could then never be met again, `hasDrainedFullReplay` would stay false
            // for the rest of the session, and that flag is what Task 9's `pushSpaces` guard
            // reads before it publishes anything.
            mutateSpaceTable { table in
                table.drainInProgress = true
                table.hasDrainedFullReplay = false
            }
        }
        // Refresh the account profile list BEFORE the paging loop on purpose:
        // the bindings this round pulls must resolve against the mapping this
        // round just refreshed, or a Space a peer published seconds ago has to
        // park for a whole round.
        if spaceLive, !didRefreshProfilesThisRound, let spaceAccess {
            let elapsed = now() - lastProfileRefreshAtMs
            if lastProfileRefreshAtMs == 0 || elapsed >= Self.profileRefreshMinIntervalMs {
                didRefreshProfilesThisRound = true
                let outcome = await spaceAccess.refreshAccountProfiles()
                // The refresh is an `await`: retirement / sign-out / an account
                // switch can land inside it (§5.4 discipline).
                guard !isStopped else { return false }
                // A FAILED refresh does not arm the interval, or "retry next
                // round" would be contradicted by the throttle itself. `.skipped`
                // does not arm it either -- nothing ran.
                if outcome != .failed, outcome != .skipped { lastProfileRefreshAtMs = now() }
                // §11's two profile fields. `skipped` is the default the counter
                // struct starts with, so the branches that never reach here
                // (gate shut, already refreshed, inside the interval) report it
                // by construction -- and §11 is explicit that it is not a failure.
                switch outcome {
                case .failed: spaceCounters.profileRefresh = "failed"
                case .skipped: spaceCounters.profileRefresh = "skipped"
                case .unchanged, .changed: spaceCounters.profileRefresh = "ok"
                }
                spaceCounters.profilesCreated = await spaceAccess.profilesCreatedInLastRefresh()
            }
        }
        // Initialize owned kinds by reading local rows/tables and seeding tag indices from cursor
        // keys plus local identities. Section 4.8 fixes ordering: local read, landing, recheck,
        // baseline write, then diff/publication. This initial load does not arm loss replay;
        // publication's reload detects loss, clears the marker/drain state and stops this round's
        // publication so the next round replays the full type (CASE 6.26).
        if spaceLive { await beginOwnedRound() }
        // A snapshot, used for the cursor keys it carries and never written back.
        let tagIndex = spaceLive ? await spaceTagIndex(table: spaceTableAtEntry) : [:]

        // Round-level state stays outside the page loop (RR-B11). Only a pull that starts without a
        // marker and drains all pages establishes absence. Capture the marker before guard 2 acts
        // (ruling 1), so empty-table replay against an account with no settings entity does not
        // redundantly clear its settings cursor.
        let startedFromScratch = storedMarker == nil
        // What guard 2's first trigger compares against. `storedMarker`'s setter maps an empty
        // marker to *absent*, so "the marker did not move" is spelled "unchanged", never
        // "nil": the protocol client answers with `Data()` when the server sent no marker for
        // the type, and a response's `newMarker` is non-optional.
        let markerAtEntry = storedMarker
        // Only a gated-off round records marker movement, and only once per round: the flag
        // is a boolean, so the first page that moves the marker has already said everything
        // there is to say. `spaceStore != nil` keeps a settings-only engine (M3-1) out of the
        // Space table entirely.
        let recordsGatedMarkerMoves = !spaceLive && spaceStore != nil
        var markerMoveRecorded = false
        // Settings visibility is round-scoped (R-M3-4a-38). The entity appears at most once in a
        // drain; absent means no page carried it. Evaluating absence per page would discard the
        // cursor created on an earlier page. sawSettingsEntity tracks the full drain.
        var view = RemoteView.absent
        var sawSettingsEntity = false
        var markerSuppression = MarkerSuppression.none
        var maySettingsPublish = true
        // Always advance the in-memory request marker page by page (R-M3-4a-76). Suppression
        // controls storedMarker persistence, not which page to request next.
        var marker = storedMarker
        var pages = 0
        var more = true
        var drained = false

        // Guard 2's empty-table replay is round-scoped, outside pagination, and reads
        // spaceTableAtEntry (R-M3-4a-37/47). Use a one-shot flag, not
        // hadRecords/hasDrainedFullReplay, to avoid endless replay when all Space entities are
        // unreadable.
        // Persist the nil marker before consuming the latch (R-M3-4a-89 / ruling 3). JSON and plist
        // cannot commit atomically, so perform the retryable step first. Any failure yields
        // cursorSaveFailed with zero pages/publication. The unsafe old-marker/consumed-latch state
        // must be unreachable: only resetForNewStoreBirthday resets that permanent latch.
        if spaceLive, spaceTableAtEntry.cursors.isEmpty, spaceTableAtEntry.hadRecords,
           !spaceTableAtEntry.didReplayForEmptyTable {
            // First persist a nil marker. On failure, stop with canPublishThisRound still false: no
            // pages or publication, and replay remains retryable.
            guard persistStoredMarker(nil) else {
                roundOutcome = .cursorSaveFailed
                return false
            }
            // Only after the marker write succeeds, consume the latch and arm the drain. A failed
            // flag write rolls memory back (R-M3-4a-83), leaving nil marker/unconsumed latch so
            // guard 2 retries safely. Re-clearing an already nil marker is a no-write success.
            guard mutateSpaceTable({ table in
                table.didReplayForEmptyTable = true
                table.hasDrainedFullReplay = false
                table.drainInProgress = true
            }) else {
                roundOutcome = .cursorSaveFailed
                return false
            }
            AppLogWarn("[phi-sync] space table is empty but had records; replaying data type \(PhiSyncEntity.dataTypeID) once")
            // Update in-memory round state only after both durable writes succeed.
            marker = nil                                    // Restart this round from the beginning.
            markerSuppression = .resetToNil                 // Do not persist markers on subsequent pages.
        }
        // Maintain hadRecords before pagination using the entry snapshot (ruling 2). Setting it
        // after page 1 lands would change guard 2's meaning within the same round. Newly created
        // cursors set it next round, which is sufficient to detect a formerly populated table that
        // was lost.
        if spaceLive, !spaceTableAtEntry.cursors.isEmpty, !spaceTableAtEntry.hadRecords {
            mutateSpaceTable { $0.hadRecords = true }
        }

        do {
            pageLoop: while more, pages < Self.maxPullPages {
                let response = try await client.getUpdates(marker: marker, storeBirthday: storedBirthday)
                guard !isStopped else { return false }
                // Persist birthday changes page by page; a changed birthday invalidates the marker
                // in the same file (section 2.4 note 1). persistMarkerState counts failures. This
                // page can still land, but its marker cannot advance on failure.
                storedBirthday = response.storeBirthday
                // Defer marker persistence until the page's final write (R-M3-4a-18).
                let pageMarker = response.newMarker
                more = response.changesRemaining
                pages += 1
                roundPages += 1

                // Page-local arrival batches. Once each page lands, no consumed entities remain
                // unlanded across pages; a later getUpdates error therefore has nothing to park.
                var batch = SpacePullBatch()
                var ownedBatches: [String: OwnedPullBatch] = [:]
                var pageCarriedSettingsEntity = false
                for entity in response.entities {
                    guard entity.clientTagHash == PhiSyncEntity.settingsClientTagHash else {
                        // Route non-settings entities only with the Space gate open. Section 5.1
                        // routes by tag-hash indices before decrypting: tombstones contain no
                        // ciphertext and cannot be classified by a decrypt-then-switch path.
                        guard spaceLive else { continue }
                        if tagIndex[entity.clientTagHash] != nil {
                            routeSpaceEntity(entity, key: key, tagIndex: tagIndex, into: &batch)
                            continue
                        }
                        // Try registered kinds against their engine-owned ownedTagIndices[label].
                        if let registration = ownedKinds.first(where: {
                            ownedTagIndices[$0.label]?[entity.clientTagHash] != nil
                        }) {
                            routeOwnedEntity(registration, entity, key: key,
                                             decoded: nil, into: &ownedBatches)
                            continue
                        }
                        // An unknown ciphertext-bearing create can still be decoded and matched to
                        // a registration before its local index exists. Return tombstones,
                        // unreadable ciphertext and unrecognized payloads to Space routing,
                        // preserving its unknown-tag behavior: log unknown tombstones, quarantine
                        // unreadable payloads and ignore other kinds.
                        if !entity.deleted, !ownedKinds.isEmpty,
                           let decoded = try? PhiEntityCodec.decrypt(entity.ciphertext, key: key),
                           let registration = ownedKinds.first(where: {
                               $0.identity(decoded) != nil
                           }) {
                            routeOwnedEntity(registration, entity, key: key,
                                             decoded: decoded, into: &ownedBatches)
                            continue
                        }
                        routeSpaceEntity(entity, key: key, tagIndex: tagIndex, into: &batch)
                        continue
                    }
                    if !entity.entityId.isEmpty { storedEntityId = entity.entityId }
                    // Take max(version), like `harvestTriple`: pagination and replayed pages can
                    // serve the same entity repeatedly, and a re-served older version would lower
                    // the base the next commit sends and buy a CONFLICT round for nothing. The
                    // resets that legitimately lower it — a new store birthday, an account switch,
                    // the tombstone heal — go through `clearEntityCursor()` instead.
                    storedVersion = max(storedVersion ?? 0, entity.version)
                    // Update the round-level settings view; all four branches count as this page
                    // carrying a settings entity (R-M3-4a-38).
                    sawSettingsEntity = true
                    pageCarriedSettingsEntity = true
                    guard !entity.deleted else {
                        // A tombstone from another device: nothing to apply, and nothing to
                        // publish either — re-committing this device's snapshot on top of it
                        // would silently undelete the account's settings (the server's
                        // client_tag unique index reuses the tombstoned row).
                        view = .unusable(reason: .tombstone)
                        continue
                    }
                    do {
                        let decoded = try PhiEntityCodec.decrypt(entity.ciphertext, key: key)
                        guard case .setting(let setting)? = decoded.kind else {
                            AppLogWarn("[phi-sync] remote entity carries no settings payload; ignoring")
                            view = .unusable(reason: .foreignPayload)
                            continue
                        }
                        view = .usable(setting)
                    } catch {
                        // Wrong key (a re-mint this device has not caught up with, or a peer
                        // sealing with an envelope version this build rejects) or corrupt
                        // bytes. Never apply it, and never publish over it.
                        AppLogError("[phi-sync] cannot open remote entity version=\(entity.version) ciphertext_bytes=\(entity.ciphertext.count) (\(PhiSyncLog.describe(error)))")
                        view = .unusable(reason: .undecryptable)
                    }
                }

                // Land this page in the same order formerly used at round end.
                switch view {
                case .usable(let remote) where pageCarriedSettingsEntity:
                    tombstoneRounds = 0
                    unreadableSettingsRecord = nil
                    // Wholesale only until this device has settings history of its own — which
                    // is `hasAdopted`, not "do we know which row they live in": a cursor
                    // dropped by the tombstone heal or the full-replay branch must not cost
                    // this device its local timestamps. See `apply` and `hasAdopted`.
                    apply(remote, adopt: !hasAdopted)
                case .unusable(let reason) where pageCarriedSettingsEntity:
                    // Unreadable settings must neither land nor authorize a settings push using the
                    // harvested ID/version, which could overwrite data from a newer client. The
                    // marker is NOT rewound (review A3): it is shared with every other kind, and
                    // rewinding it re-downloaded the whole type every round and held the drain —
                    // and every Space and owned-item publication — for as long as the entity
                    // stayed unreadable. The refusal is recorded durably instead, keyed on the
                    // domain key and build it was refused under; the entry of a later pull replays
                    // the type once when either has changed. Pages keep landing (R-M3-4a-76).
                    unreadableSettingsRecord = UnreadableSettingsRecord(
                        reason: reason.rawValue, keyFingerprint: keyFingerprint,
                        build: Self.buildIdentity)
                    // The baseline goes with the record, and that is what makes the refusal
                    // durable rather than a one-round suppression. `push`'s guard reads "an
                    // entity id with no baseline" as "the server holds bytes this device has not
                    // read"; a device that had synced before would otherwise keep the baseline
                    // it decrypted at an older version, and the next debounced local change —
                    // or the conflict retry, which reaches the scoped publisher and never sees
                    // `maySettingsPublish` — would commit over the unreadable entity using the
                    // id and version harvested from it right here. `storedEntityId` survives
                    // (the server always sends a non-empty `id_string`:
                    // internal/chromiumsync/getupdates.go toSyncEntity, from the UUID commit.go
                    // assigns on create), so no `version = 0` create can slip past the
                    // unreadable-baseline guard either. `apply` re-establishes the baseline as
                    // soon as a pull can read the entity again.
                    storedLastEntity = nil
                    maySettingsPublish = false
                    noteUnusable(reason)
                default:
                    break                       // Handle `.absent` at round scope after the loop.
                }

                if spaceLive {
                    flushSpaceObservations(batch)
                    flushOwnedObservations(ownedBatches)
                    // One load/apply/write per page is safe only in this serialized path:
                    // applySpaces spans main-actor suspensions, but gate changes and both local
                    // Space intents are queued rounds, so no other writer interleaves. Load after
                    // flushSpaceObservations because landing clears unreadableTagHashes; loading
                    // earlier would restore this page's quarantine state. Guard 2 reads its entry
                    // snapshot before pagination (section 2.4 note 6).
                    var spaceTable = loadSpaceTable()
                    spaceCounters.pulled += batch.decoded.count + batch.tombstones.count
                    await applySpaces(batch, table: &spaceTable)
                    await applySpaceTombstones(batch, table: &spaceTable)
                    writeSpaceTable(spaceTable)

                    // Land settings, Spaces, then registered owned kinds (section 5.2), allowing a
                    // new Space and its tree to land in the same page. Invalidate mappings per page
                    // (R-M3-4a-39) so owned rows can resolve Spaces just created here rather than
                    // parking on an older snapshot.
                    ownedMapsThisRound = nil
                    let ownedMaps = await ownedRoundMaps()
                    for registration in ownedKinds {
                        await retryParkedOwnedClaims(registration, maps: ownedMaps)
                    }
                    for (index, registration) in ownedKinds.enumerated() {
                        await applyOwnedKind(registration,
                                             batch: ownedBatches[registration.label] ?? OwnedPullBatch(),
                                             maps: ownedMaps)
                        // Section 12.2 Q-12: crash window after kind 1 lands but before kind 2,
                        // exercising partial cross-kind page landing. No-op in release builds.
                        if index == 0 { abortIfRequested(.betweenKinds) }
                    }
                }
                // Section 12.2 Q-12: all landing finished, marker not yet persisted.
                abortIfRequested(.afterApply)

                // Persist the marker last (section 2.5). Any cursor/table/mapping/marker failure
                // blocks this page's advancement and the round's publication. Earlier fully
                // persisted pages remain committed.
                if cursorSaveFailures > 0 {
                    roundOutcome = .cursorSaveFailed
                    break pageLoop
                }
                // Always advance the in-memory request marker (R-M3-4a-76); only storedMarker is
                // subject to suppression.
                marker = pageMarker
                if markerSuppression == .none {
                    if recordsGatedMarkerMoves, !markerMoveRecorded,
                       Self.normalizedMarker(marker) != markerAtEntry {
                        // Record marker movement with the gate closed without inspecting page
                        // content, because unreadable entities are precisely what may be missed.
                        // Persist the replay flag before the marker (R-M3-4a-77). The opposite
                        // order could permanently skip a page if the flag write fails; a false
                        // positive only causes safe replay.
                        guard mutateSpaceTable({ $0.markerMovedWhileGateShut = true }) else {
                            roundOutcome = .cursorSaveFailed
                            break pageLoop
                        }
                        markerMoveRecorded = true       // Set only after the write is acknowledged.
                    }
                    // Persist to marker.json (R-M3-4a-18).
                    guard persistStoredMarker(marker) else {
                        roundOutcome = .cursorSaveFailed
                        break pageLoop
                    }
                    if storedMarker != markerAtEntry { roundMarkerAdvanced = true }
                }
            }
            drained = !more
            if !drained, pages >= Self.maxPullPages { roundOutcome = .pageBudgetExhausted }
            // Finalize drain only if no marker suppression or cursor-save failure occurred
            // (RR2-11). A round that did not persist its page markers cannot claim a complete
            // replay.
            if spaceLive, drained, markerSuppression == .none, roundOutcome != .cursorSaveFailed {
                let stamped = mutateSpaceTable { table in
                    guard table.drainInProgress else { return }
                    table.drainInProgress = false
                    table.hasDrainedFullReplay = true
                    table.lastDrainedBirthday = storedBirthday
                }
                // A derived-state save failure also fails the round (CASE B2-4b); the write helper
                // already counted it.
                if !stamped { roundOutcome = .cursorSaveFailed }
            }
        } catch PhiSyncProtocolError.notMyBirthday {
            // Nothing to flush: the store those pages came from is gone, and
            // `resetForNewStoreBirthday()` clears the Space table's server-side state and its
            // unreadable-tag record wholesale.
            roundOutcome = .notMyBirthday
            resetForNewStoreBirthday()
            guard retryOnBirthday else { return false }
            return await pull(retryOnBirthday: false, thenPush: thenPush)
        } catch {
            roundOutcome = .pullFailed
            AppLogError("[phi-sync] pull failed device=\(deviceKeyId) (\(PhiSyncLog.describe(error)))")
            // On getUpdates failure, honor suppression and perform no other page cleanup
            // (R-M3-4a-47): prior pages fully landed, and this page never arrived. If a full drain
            // is still armed, rewind the marker so a later incremental continuation cannot
            // incorrectly mark a gapped replay complete. Keep drainInProgress true; rereading old
            // pages is preferable to enabling owned publication across a gap (ruling 10).
            if spaceLive, loadSpaceTable().drainInProgress {
                AppLogWarn("[phi-sync] a drain of data type \(PhiSyncEntity.dataTypeID) was interrupted; replaying it rather than resuming past the gap")
                storedMarker = nil
            }
            return false
        }

        // Round-level absent handling: no page in the drain carried settings (R-M3-4a-38).
        if !sawSettingsEntity, roundOutcome != .cursorSaveFailed {
            if unreadableSettingsRecord?.reason == UnusableReason.tombstone.rawValue {
                // The marker walked past the tombstone in an earlier round (review A3), so the
                // server no longer re-sends it; the durable record says the row is still gone,
                // and every pull that finds no replacement counts towards the heal.
                noteUnusable(.tombstone)
            } else {
                tombstoneRounds = 0
            }
            if drained, startedFromScratch, storedEntityId != nil {
                // A full replay carried no settings entity: the row this device points at is
                // gone (a namespace change, a targeted delete, a partial restore). Keeping the
                // id would make every later commit an update the server answers with
                // INVALID_MESSAGE forever; dropping it lets the next push create instead.
                AppLogWarn("[phi-sync] full replay carried no settings entity; dropping the stale entity cursor")
                clearEntityCursor()
            }
        }
        if markerSuppression == .resetToNil {
            // Guard-2 suppression only (review A3): idempotent re-clear of the nil marker.
            storedMarker = nil
        }
        if roundOutcome == .ok, case .unusable = view { roundOutcome = .unusableSettings }
        // The gated-off round's `markerMovedWhileGateShut` needs no write here: it was
        // persisted by the page that observed it, before that page's marker (R-M3-4a-77).

        // Publish locally winning/missing settings fields by comparing with the remote baseline, so
        // a pure remote apply sends nothing. Settings and Space publication remain independent
        // (section 5.2 change 3); unreadable settings do not invalidate Space guards.
        // The shared prerequisite is the conjunction of drained, !isStopped and zero
        // cursorSaveFailures (R-M3-4a-88/92): complete remote view, current account, and successful
        // local persistence. Set it here, not only in the following if, because pull returns it to
        // push and all conflict-retry publication paths.
        canPublishThisRound = drained && !isStopped && cursorSaveFailures == 0
        if thenPush, canPublishThisRound {
            if maySettingsPublish {
                await pushSettings(retryOnConflict: false)
            }
            await pushSpaces(retryOnConflict: false)
            // Publish owned kinds after Spaces (section 5.2). Their gate, drain and failed-read
            // guards are internal; an empty registry returns immediately.
            await pushOwnedItems(retryOnConflict: true)
        }

        if !drained, followUpRoundsUsed < Self.maxFollowUpRounds {
            // The page budget ran out with `changes_remaining` still set. Wait out the 60 s
            // timer and a first sync turns into minutes; the follow-up continues from the
            // marker this round already advanced.
            followUpRoundsUsed += 1
            Task { [weak self] in await self?.pullOnce() }
        } else if drained {
            followUpRoundsUsed = 0
        }
        return canPublishThisRound
    }

    /// What one pull collected for the Space section.
    private struct SpacePullBatch {
        var decoded: [(uuid: String, entity: Phi_PhiSpaceEntity, entityId: String, version: Int64)] = []
        var tombstones: [(uuid: String, entityId: String, version: Int64)] = []
        var unreadableHashes: [String] = []
        var unknownTombstoneHashes: [String] = []
    }

    /// Persists what this round's routing learned about entities the shared marker has
    /// already moved past. Called on the pull's tail *and* from its failure path, because the
    /// marker advance those observations describe is durable either way: a hash recorded only
    /// on the success path is lost by the throw that follows it, and nothing will ever deliver
    /// that entity again.
    private func flushSpaceObservations(_ batch: SpacePullBatch) {
        guard !batch.unreadableHashes.isEmpty else { return }
        let seenAt = now()
        mutateSpaceTable { table in
            for hash in batch.unreadableHashes { table.unreadableTagHashes[hash] = seenAt }
        }
    }

    /// Rebuild client_tag_hash-to-space_uuid routing once per pull. Tombstones lack ciphertext/UUID
    /// and SHA1 is one-way. Seed with cursor keys, mapping values and default-space (D6): a freshly
    /// paired Space can receive a tombstone before its first commit creates a cursor. Never seed
    /// local Space IDs, which are not wire identities.
    private func spaceTagIndex(table: PhiSpaceSyncTable) async -> [String: String] {
        var uuids = Set(table.cursors.keys)
        uuids.insert(SyncableSpaces.defaultSpaceUuid)
        if let spaceAccess {
            for uuid in await spaceAccess.allSpaceMappings().values { uuids.insert(uuid) }
        }
        var index: [String: String] = [:]
        for uuid in uuids {
            index[PhiSyncEntity.clientTagHash(for: PhiSyncEntity.spaceClientTag(uuid))] = uuid
        }
        return index
    }

    /// §5.2 steps 2-5, in this exact order.
    private func routeSpaceEntity(_ entity: PhiRemoteEntity,
                                  key: SymmetricKey,
                                  tagIndex: [String: String],
                                  into batch: inout SpacePullBatch) {
        let shortHash = String(entity.clientTagHash.prefix(8))

        // 2. Tombstone FIRST, before any decrypt attempt. A deleted row's specifics are the
        // type's default value the server backfilled, so its ciphertext is empty and
        // decrypting it necessarily throws — routing it after the decrypt would classify every
        // remote delete as "unreadable" and, since the marker has already moved past this
        // page, lose it forever.
        guard !entity.deleted else {
            guard let uuid = tagIndex[entity.clientTagHash] else {
                // Nothing to hide: this device has neither the row nor a cursor, and the
                // server has already replaced the specifics, so no create for that row can
                // ever arrive again.
                AppLogInfo("[phi-sync] ignoring a tombstone for an unknown tag hash=\(shortHash)")
                batch.unknownTombstoneHashes.append(entity.clientTagHash)
                return
            }
            batch.tombstones.append((uuid: uuid, entityId: entity.entityId, version: entity.version))
            return
        }

        // 3. Decrypt.
        let decoded: Phi_PhiEntity
        do {
            decoded = try PhiEntityCodec.decrypt(entity.ciphertext, key: key)
        } catch {
            AppLogWarn("[phi-sync] cannot open a space entity tag=\(shortHash) ciphertext_bytes=\(entity.ciphertext.count) (\(PhiSyncLog.describe(error)))")
            batch.unreadableHashes.append(entity.clientTagHash)
            return
        }

        // 4. Unknown kind: ignore ONLY this entity. With two kinds live, a newer client's
        // third kind is normal traffic — the settings path's `.foreignPayload` reaction
        // (rewind the marker, drop the baseline, suppress the trailing push) would drag
        // settings down with it.
        guard case .space(let space)? = decoded.kind else { return }

        // 5. The payload must hash back to the tag it arrived under.
        let expected = PhiSyncEntity.clientTagHash(for: PhiSyncEntity.spaceClientTag(space.spaceUuid))
        guard expected == entity.clientTagHash else {
            AppLogError("[phi-sync] space payload does not hash back to its tag=\(shortHash)")
            batch.unreadableHashes.append(entity.clientTagHash)
            return
        }
        batch.decoded.append((uuid: space.spaceUuid, entity: space,
                              entityId: entity.entityId, version: entity.version))
    }

    // MARK: - Space apply (§6.2 A0-A3)

    /// Lands everything one pull collected. Never throws: a failed landing parks
    /// its entity and the round moves on.
    private func applySpaces(_ batch: SpacePullBatch, table: inout PhiSpaceSyncTable) async {
        guard !isStopped, let spaceAccess else { return }
        // What this page found on disk; restored if the page's account-wide reorder fails
        // (review A6), so no baseline outlives the local write it describes.
        let tableAtEntry = table

        // §3.5 fallback A is transient by design. As soon as a held binding
        // resolves -- §3.6 created the profile, or a dead mapping was rebuilt --
        // re-land the baseline so the row actually moves onto that profile.
        // Without this the hold survives (no new entity for that uuid will ever
        // arrive: the shared marker has moved past it) and the Space stays bound
        // to the wrong profile forever.
        //
        // These entities go to the loop below DIRECTLY rather than through
        // `cursor.pendingApply`, and carry `fromServer: false`. A re-park is this
        // device's own baseline, NOT something the server sent, and `pendingApply`
        // holds bytes with no room for that distinction. Landing one must
        // therefore leave `server` alone: recording the local baseline as "what
        // the server holds" makes `spaceCommitEntries`' `toSend == server`
        // permanently true for every field this device still owes the account,
        // and the owed value is never published again.
        var reparked: [String: Phi_PhiSpaceEntity] = [:]
        for (uuid, cursor) in table.cursors {
            guard let held = cursor.heldProfileUuid,
                  cursor.pendingApply == nil,
                  let bytes = cursor.reconciled,
                  let entity = try? Phi_PhiSpaceEntity(serializedBytes: bytes),
                  await spaceAccess.localProfileId(forGlobalUuid: held) != nil else { continue }
            reparked[uuid] = entity
        }

        // Everything parked earlier is retried alongside this round's arrivals,
        // oldest cursor first so ordering is device-independent.
        var pending: [(uuid: String, entity: Phi_PhiSpaceEntity, entityId: String,
                       version: Int64, fromServer: Bool)] = []
        for (uuid, cursor) in table.cursors.sorted(by: { $0.key < $1.key }) {
            if let entity = reparked[uuid] {
                pending.append((uuid: uuid, entity: entity, entityId: cursor.entityId ?? "",
                                version: cursor.version, fromServer: false))
                continue
            }
            guard let bytes = cursor.pendingApply,
                  let entity = try? Phi_PhiSpaceEntity(serializedBytes: bytes) else { continue }
            pending.append((uuid: uuid, entity: entity, entityId: cursor.entityId ?? "",
                            version: cursor.version, fromServer: true))
        }
        let incoming = batch.decoded.sorted { $0.uuid < $1.uuid }
            .map { (uuid: $0.uuid, entity: $0.entity, entityId: $0.entityId,
                    version: $0.version, fromServer: true) }
        let all = pending.filter { p in !incoming.contains { $0.uuid == p.uuid } } + incoming

        // R2.1: fold every landed Space stamp into logical time BEFORE the projection below
        // stamps anything, so this round cannot issue a stamp under a value it just landed.
        for item in all { observeStamps(of: item.entity) }

        // Capture actual local edits before any incoming entity changes the rows or their
        // order. Merging the old reconciled bytes alone would erase an unpublished rename,
        // rebind, or drag during the pull that now precedes every local push.
        var localProjections: [String: Phi_PhiSpaceEntity] = [:]
        if !all.isEmpty {
            let spaces = await spaceAccess.currentSpaces()
            var uuidBySpace: [String: String] = [:]
            var uuidByProfile: [String: String] = [:]
            for space in spaces {
                uuidBySpace[space.spaceId] = await spaceAccess.syncUuid(forSpaceId: space.spaceId)
                if uuidByProfile[space.profileId] == nil {
                    uuidByProfile[space.profileId] = await spaceAccess.globalUuid(forProfileId: space.profileId)
                }
            }
            var projectionTable = table
            var withHistory: Set<String> = []
            for (uuid, cursor) in table.cursors {
                guard let bytes = cursor.reconciled,
                      (try? Phi_PhiSpaceEntity(serializedBytes: bytes)) != nil else { continue }
                withHistory.insert(uuid)
                // Publication still rejects parked rows. Their local edits participate in
                // reconciliation once a baseline exists; first adoption stays wholesale.
                projectionTable.cursors[uuid]?.pendingApply = nil
            }
            localProjections = SyncableSpaces.snapshot(spaces: spaces, table: projectionTable,
                                                       globalUuid: { uuidByProfile[$0] },
                                                       syncUuid: { uuidBySpace[$0] },
                                                       now: hlcNow())
                .filter { withHistory.contains($0.key) }
        }

        var landedAny = false
        for item in all {
            guard !isStopped else { return }
            var cursor = table.cursors[item.uuid] ?? PhiSpaceCursor()
            // R12: every Space log line names the entity by its client tag hash
            // prefix, never by the `space_uuid` it was derived from.
            let tag = PhiSyncEntity.clientTagHash(for: PhiSyncEntity.spaceClientTag(item.uuid))

            // §6.5: refuse to materialize agent / incognito payloads. Refusing is
            // NOT a claim the account should not hold it, so no tombstone is ever
            // pushed back; `refusedAtMs` only stops the re-decrypt every round.
            if SyncableSpaces.refuses(item.entity) {
                cursor.refusedAtMs = now()
                cursor.pendingApply = nil
                table.cursors[item.uuid] = cursor
                spaceCounters.refused += 1
                continue
            }
            // A soft-deleted uuid is never resurrected by a replayed create.
            if cursor.deletedAtMs != nil { cursor.pendingApply = nil; table.cursors[item.uuid] = cursor; continue }
            if cursor.pendingDelete {
                // A local deletion wins over a concurrent live update. Learn the current
                // server version for its tombstone without recreating the deleted local row.
                if !item.entityId.isEmpty { cursor.entityId = item.entityId }
                cursor.version = max(cursor.version, item.version)
                cursor.pendingApply = nil
                table.cursors[item.uuid] = cursor
                table.unreadableTagHashes.removeValue(forKey: tag)
                continue
            }

            // A0: resolve the binding. From Task 11 on the mapping is refreshed
            // earlier in the SAME round (§5.2), so a Space bound to a profile the
            // peer just created lands without waiting for the next one.
            let isDefault = item.uuid == SyncableSpaces.defaultSpaceUuid
            // D6: resolve the wire UUID to a local row ID. Unresolved account Spaces are created
            // locally and mapped during landing (R-D6-7).
            var localSpaceId = await spaceAccess.localSpaceId(forSyncUuid: item.uuid)
            // The default Space resolves through a constant, not a mapping row. Dead-mapping repair
            // would incorrectly remint its local ID.
            if !isDefault, let resolved = localSpaceId, await !spaceAccess.isKnownLocalSpace(resolved) {
                // Drop a mapping whose local row no longer exists and treat the entity as unmapped.
                // This repairs both interrupted deletion and a crash between mapping-first
                // creation's two writes (R-M3-4a-87). Preserve this recovery path during
                // refactoring; it mirrors Profile-side A0.
                AppLogInfo("[phi-sync] dropping a dead space mapping; the entity will land as a new Space")
                await spaceAccess.dropSpaceMapping(forSpaceId: resolved)
                localSpaceId = nil
            }
            var profileId: String?
            if !isDefault {
                let remoteUuid = item.entity.profileUuid.stringValue
                profileId = await spaceAccess.localProfileId(forGlobalUuid: remoteUuid)
                if let resolved = profileId, await !spaceAccess.isKnownLocalProfile(resolved) {
                    // A reverse mapping whose Chromium Profile was deleted must be dropped (section
                    // 3.6's sole dead-mapping repair). Check userAssignableProfiles, not
                    // globalUuid(forProfileId:), which would merely reread the same stale mapping.
                    // Next round's missing set recreates the Profile under its registered name;
                    // otherwise every landing parks forever against a nonexistent local Profile.
                    AppLogInfo("[phi-sync] dropping a dead profile mapping; the account profile will be rebuilt next round")
                    await spaceAccess.dropMapping(forProfileId: resolved)
                    profileId = nil
                }
                if profileId == nil {
                    if cursor.reconciled == nil {
                        // Fallback B: never a row, never a baseline, never
                        // `refusedAtMs` -- park the whole entity and retry.
                        cursor.pendingApply = try? item.entity.serializedData()
                        cursor.entityId = item.entityId.isEmpty ? cursor.entityId : item.entityId
                        cursor.version = max(cursor.version, item.version)
                        table.cursors[item.uuid] = cursor
                        continue
                    }
                    // Fallback A: already landed. Keep the local binding, record
                    // the remote value, and echo it back with the BASELINE's
                    // timestamp (see `SyncableSpaces.snapshot`) so this device
                    // neither wins the field nor pings the binding back and forth.
                    // The local profile the hold is taken against is recorded with
                    // it: a later LOCAL rebind must be publishable (§3.5).
                    cursor.heldProfileUuid = remoteUuid
                    cursor.heldForLocalProfileId =
                        await spaceAccess.currentSpaces().first { $0.spaceId == localSpaceId }?.profileId
                } else {
                    // The binding resolves: any hold is obsolete. Clearing it here
                    // is the other half of §3.5 -- a stale hold would keep winning
                    // the snapshot's held branch over the mapping-derived value.
                    cursor.heldProfileUuid = nil
                    cursor.heldForLocalProfileId = nil
                }
            }

            // A1: no baseline -> adopt wholesale. A device with no timestamp
            // history that merged field by field would stamp its factory defaults
            // `now` and push them over the account's real values.
            let existing = await spaceAccess.currentSpaces().first { $0.spaceId == localSpaceId }
            // C1 / defect 0.3-2: the well-known default row is deletable now, so `land` can
            // legitimately reach its CREATE branch for this identity on a device whose row is
            // gone. D1 keeps `profile_uuid` off the wire for it, so there is no account binding
            // to resolve -- recreate it under this device's own Default profile, the same one
            // `LocalStore.ensureDefaultSpace` uses on first launch. Without this the entity
            // parks forever on `unresolvedProfile`. If that profile is not (yet) known here,
            // `land` throws and the existing catch parks and retries.
            if isDefault, existing == nil,
               await spaceAccess.isKnownLocalProfile(LocalStore.defaultProfileId) {
                profileId = LocalStore.defaultProfileId
            }
            let merged: Phi_PhiSpaceEntity
            if let bytes = cursor.reconciled,
               let baseline = try? Phi_PhiSpaceEntity(serializedBytes: bytes) {
                merged = SyncableSpaces.merge(local: localProjections[item.uuid] ?? baseline, remote: item.entity)
            } else {
                merged = item.entity
            }
            if !isDefault, merged.profileUuid.stringValue != item.entity.profileUuid.stringValue {
                // Resolve the winning binding, not the remote binding examined above.
                profileId = await spaceAccess.localProfileId(forGlobalUuid: merged.profileUuid.stringValue)
                if profileId != nil {
                    cursor.heldProfileUuid = nil
                    cursor.heldForLocalProfileId = nil
                }
            }

            // Persist the mapping before creating the row (R-M3-4a-87). SwiftData and the account
            // plist have no shared transaction, so allow only the recoverable
            // mapping-present/row-absent intermediate state repaired above. Premint the local ID;
            // land already accepts it. Exclude the implicit default Space to avoid
            // defaultSpaceIsImplicit failures that would park it every round.
            if localSpaceId == nil, !isDefault {
                let newId = UUID().uuidString
                do {
                    try await spaceAccess.mapSpace(newId, toSyncUuid: item.uuid)
                } catch {
                    AppLogWarn("[phi-sync] could not map a new space tag=\(String(tag.prefix(8))) (\(PhiSyncLog.describe(error)))")
                    // Fourth cursorSaveFailed source (ruling 7 / section 13.2). mapSpace
                    // persistence failure is persistFailed; its store already rolled back, leaving
                    // neither mapping nor row, and land has not run. Other mapping errors are
                    // decisions that park without counting a persistence failure.
                    if (error as? SpaceSyncMappingError) == .persistFailed { cursorSaveFailures += 1 }
                    if item.fromServer {
                        cursor.pendingApply = try? item.entity.serializedData()
                        table.cursors[item.uuid] = cursor
                    }
                    continue
                }
                localSpaceId = newId
            }

            // A2 + A3: land in order, await every step, and only THEN write the
            // baselines. The reverse order leaves the shadow ahead of the row and
            // the next snapshot stamps the stale value `now` for the whole account.
            let landed: String
            do {
                landed = try await SyncableSpaces.land(merged, existing: existing,
                                                       localSpaceId: localSpaceId,
                                                       profileId: profileId, access: spaceAccess)
            } catch {
                AppLogWarn("[phi-sync] space landing failed tag=\(String(tag.prefix(8))) (\(PhiSyncLog.describe(error)))")
                // A re-parked baseline is deliberately NOT written to
                // `pendingApply`: next round it would be indistinguishable from a
                // server entity and would be recorded as `server` on the retry.
                // Discarding this round's cursor edits instead leaves the hold
                // exactly as it was, so the re-park pass above picks it up again.
                if item.fromServer {
                    cursor.pendingApply = try? item.entity.serializedData()
                    table.cursors[item.uuid] = cursor
                }
                continue
            }
            guard !isStopped else { return }

            // §5.6 again, for the one write that can report success without
            // having happened: `SpaceManager.applyRemoteRebind` optional-chains
            // through `boundAccount`, so a nil account returns normally and
            // writes nothing, and `prepareProfileChange` is documented to refuse
            // silently (an import in flight, an agent Space) with "the entity is
            // retried next round" -- which is only true if this round declines to
            // write a baseline. Verify the field that has that out-of-band
            // refusal path rather than trusting the return, and park otherwise.
            if !isDefault, let profileId, let existing, existing.profileId != profileId,
               await spaceAccess.currentSpaces().first(
                   where: { $0.spaceId == landed })?.profileId != profileId {
                AppLogWarn("[phi-sync] space rebind did not take effect tag=\(String(tag.prefix(8))); parking the entity")
                if item.fromServer {   // same reason as the landing-failure park above
                    cursor.pendingApply = try? item.entity.serializedData()
                    table.cursors[item.uuid] = cursor
                }
                continue
            }

            cursor.reconciled = try? merged.serializedData()
            // `remote`, NOT `merged`: this is "what the server holds", the
            // comparison that decides whether anything still needs publishing.
            // And only for an entity that actually CAME from the server: the
            // held re-park above re-lands this device's own baseline, which says
            // nothing about the server's copy and must leave it untouched.
            if item.fromServer { cursor.server = try? item.entity.serializedData() }
            if !item.entityId.isEmpty { cursor.entityId = item.entityId }
            cursor.version = max(cursor.version, item.version)
            cursor.pendingApply = nil
            table.cursors[item.uuid] = cursor
            table.unreadableTagHashes.removeValue(forKey: tag)
            landedAny = true
            spaceCounters.applied += 1
        }

        // One account-wide reorder after every entity landed (§7).
        if landedAny {
            // Translate syncUuid cursor keys to local IDs here, before plannedOrder reads
            // syncedRanks[spaceId]. Partial translation would silently miss every lookup and make
            // account reordering a no-op (D6). The uuid rides along as the value's second half:
            // it is what equal ranks tie on, and it is only available in this namespace.
            var ranks: [String: (rank: String, uuid: String)] = [:]
            for (uuid, cursor) in table.cursors {
                guard cursor.hidden == false, cursor.deletedAtMs == nil,
                      let bytes = cursor.reconciled,
                      let entity = try? Phi_PhiSpaceEntity(serializedBytes: bytes) else { continue }
                guard let local = await spaceAccess.localSpaceId(forSyncUuid: uuid) else { continue }
                // A locally dragged sibling may have no incoming entity in this pull. Its
                // current rank must participate without advancing its unsent baseline.
                let projected = localProjections[uuid].map { SyncableSpaces.merge(local: $0, remote: entity) }
                ranks[local] = (rank: (projected ?? entity).rank.stringValue, uuid: uuid)
            }
            // `allSpacesForOrdering()`, NOT `currentSpaces()`: the result goes
            // straight to `LocalStore.reorderSpaces`, which renumbers exactly the
            // ids it is given and leaves every other row's `sortOrder` untouched.
            // Handing it the §6.5-filtered view would renumber the synced Spaces
            // 0..n-1 while agent Spaces and Spaces on unmapped profiles kept stale
            // values and interleaved arbitrarily -- the opposite of §7's "keep
            // their own slots".
            let order = SyncableSpaces.plannedOrder(
                localOrder: await spaceAccess.allSpacesForOrdering(), syncedRanks: ranks)
            do {
                try await spaceAccess.applyOrder(order)
            } catch {
                // Review A6: the rank baselines landed above already describe the peer's order.
                // Keeping them while the local strip stays stale would make the next snapshot
                // stamp this device's OLD order with a fresh timestamp and push it — reverting
                // the peer's reorder account-wide. Treat the reorder as the page's persistence
                // failure it is: roll the table back to how this page found it, count the
                // failure so the marker does not advance and nothing publishes this round, and
                // let the page replay (landing is idempotent) with the reorder retried.
                AppLogError("[phi-sync] account-wide reorder failed (\(PhiSyncLog.describe(error))); replaying this page next round")
                table = tableAtEntry
                cursorSaveFailures += 1
            }
        }
    }

    /// Remote deletes (§9.2): the pull routes them into `batch.tombstones` and
    /// this is where they are hidden locally and the cursor becomes a tombstone
    /// record.
    ///
    /// A remote delete is a first-class product event for Spaces, not the hazard
    /// the settings path treats it as: no `tombstoneRounds`, no three-round heal,
    /// no suppression of the trailing push.
    private func applySpaceTombstones(_ batch: SpacePullBatch, table: inout PhiSpaceSyncTable) async {
        guard !isStopped, let spaceAccess else { return }
        // Everything deferred by an import lock is retried alongside this round's
        // arrivals: the shared marker has already moved past those pages, so the
        // same tombstone will never be delivered again.
        var work = batch.tombstones
        for (uuid, cursor) in table.cursors.sorted(by: { $0.key < $1.key })
        where cursor.pendingTombstone && !work.contains(where: { $0.uuid == uuid }) {
            work.append((uuid: uuid, entityId: cursor.entityId ?? "", version: cursor.version))
        }

        for item in work {
            guard !isStopped else { return }
            // C1: a tombstone for the `default-space` IDENTITY lands like any other Space's.
            // This used to be refused here, on the strength of a comment claiming
            // `deleteSpace` refuses it locally -- it does not (it refuses only Incognito
            // Spaces and the last remaining user Space), so the account could hold a
            // tombstone every peer silently ignored, diverging forever. The role that used to
            // be pinned to this identity is now the account register
            // (`PhiDefaultSpaceMirror`), which is what survives the deletion; D1's field
            // suppressions stay on the identity and are unaffected by a delete.
            let isDefaultIdentity = item.uuid == SyncableSpaces.defaultSpaceUuid
            var cursor = table.cursors[item.uuid] ?? PhiSpaceCursor()
            if let entityId = cursor.entityId, !item.entityId.isEmpty, entityId != item.entityId {
                // The server never rewrites `client_tag_hash` on an update
                // (`internal/data/entities_write.go:243-244`), so the hash is the
                // stable identity and the id is only a cross-check.
                AppLogError("[phi-sync] tombstone entity id disagrees with the cursor; trusting the tag hash")
            }
            guard cursor.deletedAtMs == nil else {
                cursor.pendingTombstone = false
                table.cursors[item.uuid] = cursor
                continue
            }

            // D6: resolve the wire UUID first. With no local row, skip import-lock/hide work but
            // still finalize the tombstone cursor, preventing a future create replay from
            // resurrecting the deleted account entity.
            let localSpaceId = await spaceAccess.localSpaceId(forSyncUuid: item.uuid)
            if let localSpaceId {
                if await spaceAccess.isImporting(intoSpaceId: localSpaceId) {
                    // No modal: nobody is there to see it. Persist the intent instead.
                    cursor.pendingTombstone = true
                    table.cursors[item.uuid] = cursor
                    continue
                }
                // C1 safety case. Hiding the last live user Space leaves this device with none,
                // which is exactly the invariant `deleteSpace`'s "never delete the last user
                // Space" guard holds locally -- and nothing downstream of `hide` re-checks it.
                // The deleting device legitimately had a successor; this one may not have
                // received it yet (a later page, or a Space the pairing wizard has not mapped).
                // Defer with the same parking the import lock uses: `pendingTombstone` is
                // retried at the top of every round, so the tombstone lands as soon as any
                // other user Space is live here.
                //
                // Scoped to the default IDENTITY, which is the case this guard was added for:
                // that row exists on every device from first launch, so it is the one most
                // likely to be a device's only user Space, and until C1 its tombstone was
                // ignored outright. An ordinary Space's tombstone keeps today's behaviour
                // (hide unconditionally) -- widening the rule is a separate decision, because
                // a parked tombstone has no give-up condition (backlog B-5).
                if isDefaultIdentity, await liveLocalUserSpaceIds(table: table) == [localSpaceId] {
                    AppLogWarn("[phi-sync] deferring the default Space tombstone: it would hide the last live user Space")
                    cursor.pendingTombstone = true
                    table.cursors[item.uuid] = cursor
                    continue
                }
                do {
                    // Windows first, so a window parked on this Space retreats along
                    // the existing fallback path instead of vanishing under the user.
                    try await spaceAccess.hide(spaceId: localSpaceId)
                } catch {
                    cursor.pendingTombstone = true
                    table.cursors[item.uuid] = cursor
                    continue
                }
            }
            // Retain the mapping on remote soft deletion (R-D6-10). During the 30-day window it
            // connects the row to its tombstone and lets snapshot eligibility exclude it. Remove
            // only after successful retention purge.
            cursor.hidden = true
            cursor.deletedAtMs = now()
            cursor.pendingTombstone = false
            // The landing is TERMINAL for this uuid, so it writes the same
            // finished state §6.2 writes for a tombstone of our own: a local
            // delete queued a moment earlier (`recordLocalDeletion`) is owed to
            // nobody now that the account already holds the tombstone.
            // `spaceCommitEntries` unions EVERY `pendingDelete` cursor into the
            // next batch, so a flag left standing here ships a redundant
            // `deleted: true` commit whose `.applied` outcome re-stamps
            // `deletedAtMs = now()` -- restarting §9.2's 30-day window from the
            // echo instead of from the delete.
            cursor.pendingDelete = false
            cursor.deleteRejectRounds = 0
            cursor.pendingApply = nil
            cursor.heldProfileUuid = nil
            cursor.heldForLocalProfileId = nil
            if !item.entityId.isEmpty { cursor.entityId = item.entityId }
            cursor.version = max(cursor.version, item.version)
            table.cursors[item.uuid] = cursor
            spaceCounters.applied += 1   // §11: a remote soft delete is a landing
            // A soft delete IS a successful interpretation of that tag.
            table.unreadableTagHashes.removeValue(forKey:
                PhiSyncEntity.clientTagHash(for: PhiSyncEntity.spaceClientTag(item.uuid)))
            // Deliberately silent: a local delete has a confirmation dialog, a
            // remote one has no alert, no toast and no hint. And no data is
            // touched -- SpaceModel, bookmarks, pin tabs, URL rules and both theme
            // maps stay on disk for the whole retention window.
            AppLogInfo("[phi-sync] space soft-deleted by a remote tombstone")
        }
    }

    /// The local user Spaces a tombstone could still leave standing: `pairableSpaces()` --
    /// §6.5's identity exclusions only, so agent and Incognito Spaces are out and the default
    /// Space is in, with no mapping requirement -- minus every row this table has already
    /// hidden or soft-deleted. Recomputed per tombstone because a hide earlier in the same
    /// loop changes the answer.
    private func liveLocalUserSpaceIds(table: PhiSpaceSyncTable) async -> Set<String> {
        guard let spaceAccess else { return [] }
        var gone: Set<String> = []
        for (uuid, cursor) in table.cursors where cursor.hidden || cursor.deletedAtMs != nil {
            if let local = await spaceAccess.localSpaceId(forSyncUuid: uuid) { gone.insert(local) }
        }
        return Set(await spaceAccess.pairableSpaces().map(\.spaceId)).subtracting(gone)
    }

    /// Records a pull that could not read the account's entity, and — for a tombstone only —
    /// arms the heal once the row has been gone for `tombstoneHealAfterRounds` consecutive
    /// pulls. Arming just drops the entity cursor: this never publishes anything, so a
    /// deliberate deletion survives until some device actually changes a setting, and only then
    /// does the commit go out as a create (`baseVersion = 0`, no entity id) that the server
    /// resolves through its `ON CONFLICT (client_tag_hash) DO UPDATE` path.
    ///
    /// Logged at error level: both refusals leave settings sync dead for the whole account, and
    /// `AppLogWarn`/`AppLogError` are the only levels that reach the shipped log file (release
    /// installs the loggers at `.info`, `Logging.swift`), so this is the one support-visible
    /// trace of a state the user cannot see or fix.
    private func noteUnusable(_ reason: UnusableReason) {
        guard reason == .tombstone else {
            // Real content this build must not overwrite; nothing here may re-create it, and a
            // non-tombstone round breaks the streak.
            tombstoneRounds = 0
            AppLogError("[phi-sync] settings entity is unusable (\(reason.rawValue)); not applying it and not publishing over it")
            return
        }
        let rounds = tombstoneRounds + 1
        tombstoneRounds = rounds
        guard rounds >= Self.tombstoneHealAfterRounds else {
            AppLogWarn("[phi-sync] settings entity is a tombstone (round \(rounds)/\(Self.tombstoneHealAfterRounds)); not applying it and not publishing over it")
            return
        }
        AppLogError("[phi-sync] settings entity has been a tombstone for \(rounds) consecutive pulls; dropping the entity cursor so the next local change re-creates it")
        clearEntityCursor()
        // The heal is complete: the row is forgotten and the next local change creates. Forget
        // the record too, or every later pull would count and "heal" again (review A3).
        unreadableSettingsRecord = nil
        tombstoneRounds = 0
    }

    private func apply(_ remote: Phi_PhiSettingEntity, adopt: Bool) {
        // A retired engine decrypted these settings with the signed-out account's domain key;
        // writing them now would hand the account mounted next the previous account's values.
        // This entry check only saves the merge work — `shutdown()` is concurrent with this
        // round, so what actually stops the writes is the check each of them makes for itself
        // (`snapshotLocalSettings`, `writeSettings`, `writeState`).
        guard !isStopped else { return }
        // R2.1: observe before `snapshotLocalSettings()` below stamps anything, so a key this
        // device is about to restamp cannot be stamped under the value it is overwriting.
        observeStamps(of: remote)
        // A device with no settings history has no timestamps to compare against: every key it
        // snapshots would be stamped `now` and beat the account's real edits. So the first pull
        // adopts the account's entity wholesale; later pulls merge field by field.
        let merged: Phi_PhiSettingEntity
        if adopt {
            merged = remote
        } else {
            guard let local = snapshotLocalSettings() else { return }
            merged = SyncableSettings.merge(local: local, remote: remote)
        }

        guard writeSettings(merged) else { return }

        // What the server holds, not what we now hold locally: `push` compares against this to
        // decide whether anything still needs publishing.
        storedLastEntity = remote
        // `apply` leaves a `<key>.phiSyncTs` sidecar behind for every key it wrote, so from
        // here on this device has timestamps a merge can compare — no later pull may adopt.
        hasAdopted = true
        AppLogInfo("[phi-sync] applied remote settings keys=\(merged.values.count)")
    }

    // MARK: - Push

    /// Pull first, then publish settings, Spaces and owned items independently under the same pull
    /// prerequisite. A steady-state settings early return must not suppress a Space-only change;
    /// sibling publication avoids the coupling forbidden by section 5.2 change 3.
    private func push(retryOnConflict: Bool) async {
        guard await pull(retryOnBirthday: true, thenPush: false) else { return }
        await pushSettings(retryOnConflict: retryOnConflict)
        await pushSpaces(retryOnConflict: retryOnConflict)
        await pushOwnedItems(retryOnConflict: retryOnConflict)
    }

    /// Publishes settings after this round's shared pull prerequisite.
    private func pushSettings(retryOnConflict: Bool) async {
        guard !isStopped, canPublishThisRound else { return }

        // A round that knows the server holds bytes it could not decode must not overwrite
        // them. `storedLastEntity` is the decrypted baseline of what the server has; an entity
        // id with no baseline means the last pull saw the entity but could not read it (bad
        // key, foreign payload, tombstone — that pull drops the baseline precisely so this
        // guard fires; a tombstone that has outlasted `tombstoneHealAfterRounds` pulls drops
        // the id too, so this guard lets that one create), or the baseline was lost with the
        // process. Committing here would
        // replace the entire entity — every key, including a newer client's — with this
        // device's snapshot. Rewind the marker so the next pull re-reads the entity and can
        // re-establish the baseline.
        //
        // This returns before `SyncableSettings.snapshot` runs, so a local change made while
        // the entity is unreadable leaves no `<key>.phiSyncTs` sidecar and never sets
        // `hasAdopted`. That is deliberate, and it has a cost on the one device that has no
        // other settings history — see `hasAdopted` for the window and why stamping here would
        // lose more than it saves.
        if storedEntityId != nil, storedLastEntity == nil {
            AppLogWarn("[phi-sync] push skipped: no readable baseline for the settings entity the server holds")
            storedMarker = nil
            return
        }

        let key: SymmetricKey
        do {
            key = try await domainKeys.domainKey()
        } catch {
            AppLogWarn("[phi-sync] push skipped: domain key unavailable (\(PhiSyncLog.describe(error)))")
            return
        }
        // Nothing below suspends before `client.commit`, so this check is the last thing that
        // can keep a retired round from publishing the signed-out account's settings — the
        // token provider behind the client now mints the *new* account's bearer token. It
        // cannot be airtight (a `shutdown()` landing between here and URLSession's send is not
        // seen), which `shutdown()` documents; what it does rule out is a round that resumed
        // from the network long after sign-out going on to commit.
        guard !isStopped, canPublishThisRound else { return }

        let last = storedLastEntity
        // A snapshot is a write too — it stamps the sidecars — so it makes its own check.
        guard let local = snapshotLocalSettings() else { return }
        // Merging against the last known server entity keeps keys this build does not know
        // about (a newer client's settings) instead of deleting them on every push.
        let outgoing = SyncableSettings.merge(local: local, remote: last ?? Phi_PhiSettingEntity())
        if let last, outgoing == last { return }

        var wrapper = Phi_PhiEntity()
        wrapper.setting = outgoing

        do {
            let ciphertext = try PhiEntityCodec.encrypt(wrapper, key: key)
            // The settings entity is still exactly one entry: a one-element batch, committed
            // under `phi-settings` as before. `name` moved from the client into the entry, so
            // it is spelled out here rather than defaulted.
            let outcomes = try await client.commit(entries: [
                PhiCommitEntry(entityId: storedEntityId,
                               clientTagHash: PhiSyncEntity.settingsClientTagHash,
                               name: PhiSyncEntity.clientTag,
                               ciphertext: ciphertext,
                               deleted: false,
                               baseVersion: storedVersion ?? 0),
            ], storeBirthday: storedBirthday)
            guard !isStopped else { return }
            guard let outcome = outcomes.first else {
                throw PhiSyncProtocolError.malformedResponse
            }
            switch outcome {
            case .applied(let entityId, let version, let storeBirthday):
                if !entityId.isEmpty { storedEntityId = entityId }
                storedVersion = version
                storedBirthday = storeBirthday
                storedLastEntity = outgoing
                // Whatever the row was before, it now holds bytes this device wrote and can
                // read: any tombstone streak is over.
                tombstoneRounds = 0
                // A published snapshot is settings history too — `SyncableSettings.snapshot`
                // stamped a sidecar timestamp for every registered key on the way here, and
                // those are exactly what a later merge compares against.
                hasAdopted = true
                AppLogInfo("[phi-sync] pushed settings keys=\(outgoing.values.count) version=\(version)")
            case .conflict(let serverVersion):
                guard retryOnConflict else {
                    AppLogWarn("[phi-sync] commit still conflicting server_version=\(serverVersion.map(String.init) ?? "unknown"); abandoning this round")
                    return
                }
                guard await pull(retryOnBirthday: true, thenPush: false) else { return }
                // `pushSettings`, not `push`: this retry is the settings entity's
                // own, and the Space half of this round has not run yet.
                await pushSettings(retryOnConflict: false)
            case .invalidMessage:
                // The same rejection as the `commitRejected(.invalidMessage)` catch below, only
                // reported per entry instead of thrown for the whole batch. Both paths exist:
                // a peer that fails the round still throws.
                dropTheEntityCursorAfterInvalidMessage()
            case .rejected(let responseType):
                AppLogError("[phi-sync] commit rejected response_type=\(responseType); abandoning this round")
                return
            }
        } catch PhiSyncProtocolError.notMyBirthday {
            resetForNewStoreBirthday()
        } catch PhiSyncProtocolError.commitRejected(.invalidMessage) {
            dropTheEntityCursorAfterInvalidMessage()
        } catch {
            AppLogError("[phi-sync] push failed device=\(deviceKeyId) (\(PhiSyncLog.describe(error)))")
        }
    }

    /// INVALID_MESSAGE on the settings commit, however it was reported — as this batch entry's
    /// outcome, or as a thrown `commitRejected(.invalidMessage)` for the whole round.
    ///
    /// The server could not find the row this commit names: the update path returns
    /// INVALID_MESSAGE on pgx.ErrNoRows and on a data_type mismatch
    /// (internal/data/entities_write.go), and NOT_MY_BIRTHDAY never fires because the
    /// account row — and with it store_birthday — is untouched. An incremental
    /// GetUpdates cannot tell us either: it simply returns nothing. Without dropping the
    /// cursor the device would send the same stale id and version forever and never sync
    /// again. Drop the row identity and the marker so the next round replays the type
    /// from scratch and either re-discovers the entity or creates it through the
    /// client_tag_hash unique index.
    ///
    /// `clearRemoteCursor()`, never `resetSyncState()`: the account is unchanged, and
    /// the snapshot taken a few statements above has just stamped `now` on the key the
    /// user edited. Clearing `hasAdopted` here would make the very next pull adopt a
    /// peer's entity wholesale over that edit — and, because `apply` also writes the
    /// remote timestamp into the key's sidecar, the edit would never be re-pushed
    /// either. That is the same distinction the `.absent` full-replay branch makes.
    private func dropTheEntityCursorAfterInvalidMessage() {
        AppLogWarn("[phi-sync] commit rejected as INVALID_MESSAGE; dropping the entity cursor and the marker so the next round rediscovers the entity")
        clearRemoteCursor()
    }

    // MARK: - Space push (§5.1 / §5.5 guard 3 / §9.1)

    /// Assembles this round's Space commit batch. Returns the uuid alongside each
    /// entry so per-entry outcomes can be applied without re-deriving anything.
    private func spaceCommitEntries(
        from table: PhiSpaceSyncTable,
        outgoing: [String: Phi_PhiSpaceEntity]
    ) -> [(uuid: String, entry: PhiCommitEntry, outgoing: Phi_PhiSpaceEntity?)] {
        var result: [(uuid: String, entry: PhiCommitEntry, outgoing: Phi_PhiSpaceEntity?)] = []
        for uuid in Set(outgoing.keys).union(table.cursors.filter { $0.value.pendingDelete }.keys).sorted() {
            let cursor = table.cursors[uuid]
            let tagHash = PhiSyncEntity.clientTagHash(for: PhiSyncEntity.spaceClientTag(uuid))

            // Guard 3 (§5.5): the server holds a row under this tag that this
            // build cannot read. A create would take the server's
            // `ON CONFLICT (client_tag_hash) DO UPDATE` path, which has NO version
            // check, and overwrite it irrecoverably -- not a delete, so M1's
            // 30-day window does not apply either.
            guard table.unreadableTagHashes[tagHash] == nil else {
                AppLogWarn("[phi-sync] refusing to commit over an unreadable row tag=\(String(tagHash.prefix(8)))")
                continue
            }

            if let cursor, cursor.pendingDelete {
                // §9.1's second gate: a tombstone with no entityId / version 0 is
                // illegal server-side and can only loop.
                guard let entityId = cursor.entityId, cursor.version > 0 else { continue }
                result.append((uuid: uuid,
                               entry: PhiCommitEntry(entityId: entityId, clientTagHash: tagHash,
                                                     name: PhiSyncEntity.spaceEntityName,
                                                     ciphertext: nil, deleted: true,
                                                     baseVersion: cursor.version),
                               outgoing: nil))
                continue
            }

            guard let snapshot = outgoing[uuid] else { continue }
            // Merge against what the server holds so a newer client's reserved
            // fields 11-14 survive a round trip through this build.
            var toSend = snapshot
            if let bytes = cursor?.server,
               let server = try? Phi_PhiSpaceEntity(serializedBytes: bytes) {
                toSend = SyncableSpaces.merge(local: snapshot, remote: server)
                if toSend == server { continue }   // nothing to publish
            }
            result.append((uuid: uuid,
                           entry: PhiCommitEntry(entityId: cursor?.entityId, clientTagHash: tagHash,
                                                 name: PhiSyncEntity.spaceEntityName,
                                                 ciphertext: nil, deleted: false,
                                                 baseVersion: cursor?.version ?? 0),
                           outgoing: toSend))
        }
        return result
    }

    /// `onlyUuids == nil` publishes everything this round's snapshot produced;
    /// a non-nil set restricts the batch to those uuids, which is what the
    /// CONFLICT retry passes so one conflicting Space cannot drag the other
    /// twenty back through the wire.
    private func pushSpaces(retryOnConflict: Bool, onlyUuids: Set<String>? = nil) async {
        guard !isStopped, canPublishThisRound, spaceSectionEnabled, let spaceAccess, spaceStore != nil else { return }
        // The one Space read-modify-write that is not a `mutateSpaceTable` delta,
        // for the same reason as the apply path's: per-entry outcomes have to be
        // carried across the batch loop's suspension points. Safe here because
        // EVERY writer of this table is a round (`recordLocalDeletion` included)
        // and rounds are serialized, and because `pushSpaces` is the last Space
        // work of the round -- `applySpaces` has already written by the time
        // this loads.
        var table = loadSpaceTable()
        // Guard 1: not one commit -- tombstones included -- until a full replay
        // has finished, or a device that has not seen the account's Spaces yet can
        // overwrite `default-space` with its factory defaults.
        guard table.hasDrainedFullReplay else {
            if table.drainInProgress {
                AppLogInfo("[phi-sync] space push held: drain_in_progress")
            }
            return
        }

        let spaces = await spaceAccess.currentSpaces()
        guard !isStopped else { return }
        var uuidByProfile: [String: String] = [:]
        for space in spaces {
            if uuidByProfile[space.profileId] == nil {
                uuidByProfile[space.profileId] = await spaceAccess.globalUuid(forProfileId: space.profileId)
            }
        }
        // Lazy identity minting (R-D6-7). currentSpaces already excludes incognito, both agent
        // patterns and unmapped Profiles, so every candidate is publishable. A mint failure skips
        // only that Space this round and retries next round; existing/default mappings are handled
        // by the resolver.
        var syncUuidBySpaceId: [String: String] = [:]
        for space in spaces {
            syncUuidBySpaceId[space.spaceId] = try? await spaceAccess.ensureMapped(spaceId: space.spaceId)
        }
        guard !isStopped else { return }
        let outgoing = SyncableSpaces.snapshot(spaces: spaces, table: table,
                                               globalUuid: { uuidByProfile[$0] ?? nil },
                                               syncUuid: { syncUuidBySpaceId[$0] ?? nil },
                                               now: hlcNow())
        var work = spaceCommitEntries(from: table, outgoing: outgoing)
        if let onlyUuids { work = work.filter { onlyUuids.contains($0.uuid) } }
        // §9.1 second gate's bookkeeping half: an unpublished pendingDelete is
        // finalized here rather than sent.
        for (uuid, var cursor) in table.cursors where cursor.pendingDelete {
            guard cursor.entityId == nil || cursor.version == 0 else { continue }
            cursor.pendingDelete = false
            cursor.reconciled = nil
            cursor.server = nil
            cursor.deletedAtMs = now()
            table.cursors[uuid] = cursor
        }
        guard !work.isEmpty else { writeSpaceTable(table); return }

        var conflicted: Set<String> = []
        // Locally originated tombstones accepted this round (R-D6-10). Collect synchronously in
        // applySpaceCommitOutcome, then remove mappings after batching via their main-actor writer.
        var tombstonedThisRound: Set<String> = []
        var encryptionFailed = false
        while !work.isEmpty {
            let slice = Array(work.prefix(Self.maxCommitEntriesPerBatch))
            work.removeFirst(slice.count)
            var entries: [PhiCommitEntry] = []
            var payloads: [(uuid: String, entry: PhiCommitEntry, outgoing: Phi_PhiSpaceEntity?)] = []
            for item in slice {
                guard let payload = item.outgoing else {
                    entries.append(item.entry); payloads.append(item); continue
                }
                var wrapper = Phi_PhiEntity()
                wrapper.space = payload
                guard let key = try? await domainKeys.domainKey(),
                      let ciphertext = try? PhiEntityCodec.encrypt(wrapper, key: key) else {
                    // `break`, not `return`: outcomes already applied for earlier
                    // slices in this round are in `table` and must still be
                    // persisted by the `writeSpaceTable` below, or an accepted
                    // commit's baselines are silently thrown away and the next
                    // round republishes what the server already has.
                    encryptionFailed = true
                    break
                }
                entries.append(PhiCommitEntry(entityId: item.entry.entityId,
                                              clientTagHash: item.entry.clientTagHash,
                                              name: item.entry.name, ciphertext: ciphertext,
                                              deleted: false, baseVersion: item.entry.baseVersion))
                payloads.append(item)
            }
            if encryptionFailed {
                AppLogError("[phi-sync] space commit aborted: the domain key or the seal failed")
                break
            }
            guard !isStopped, canPublishThisRound else { break }
            let outcomes: [PhiCommitOutcome]
            do {
                outcomes = try await client.commit(entries: entries, storeBirthday: storedBirthday)
            } catch PhiSyncProtocolError.notMyBirthday {
                resetForNewStoreBirthday()
                return   // the reset rewrote the table itself; do not write the stale copy back
            } catch {
                AppLogError("[phi-sync] space commit failed (\(PhiSyncLog.describe(error)))")
                break    // keep the outcomes earlier slices already produced
            }
            guard !isStopped else { return }
            for (item, outcome) in zip(payloads, outcomes) {
                applySpaceCommitOutcome(outcome, for: item, table: &table,
                                        conflicted: &conflicted,
                                        tombstoned: &tombstonedThisRound)
            }
        }
        // Remove mappings for accepted local tombstones (R-D6-10); the local rows are already
        // absent, so retaining mappings would return dead IDs. Keep permanent tombstone cursors.
        // Collection occurred in synchronous applySpaceCommitOutcome; mapping writes happen here on
        // the main actor.
        for uuid in tombstonedThisRound {
            guard let local = await spaceAccess.localSpaceId(forSyncUuid: uuid) else { continue }
            await spaceAccess.dropSpaceMapping(forSpaceId: local)
        }
        writeSpaceTable(table)

        // After one pull, retry only conflicted UUIDs, not unaffected Spaces. A second conflict
        // abandons only those entries; already applied entries remain valid (section 5.1).
        if retryOnConflict, !conflicted.isEmpty {
            guard await pull(retryOnBirthday: true, thenPush: false) else { return }
            await pushSpaces(retryOnConflict: false, onlyUuids: conflicted)
        }
    }

    /// The five baseline write points of §6.2, in one place.
    ///
    /// `tombstoned` collects the uuids whose OWN tombstone the account accepted this
    /// round (R-D6-10). It is an out-parameter for the same reason `conflicted` is:
    /// this method is synchronous, and dropping the mapping row is a main-actor hop
    /// the caller makes after the batch loop.
    private func applySpaceCommitOutcome(
        _ outcome: PhiCommitOutcome,
        for item: (uuid: String, entry: PhiCommitEntry, outgoing: Phi_PhiSpaceEntity?),
        table: inout PhiSpaceSyncTable,
        conflicted: inout Set<String>,
        tombstoned: inout Set<String>
    ) {
        var cursor = table.cursors[item.uuid] ?? PhiSpaceCursor()
        let isTombstone = item.entry.deleted
        switch outcome {
        case .applied(let entityId, let version, let storeBirthday):
            if !entityId.isEmpty { cursor.entityId = entityId }
            cursor.version = version
            storedBirthday = storeBirthday
            if isTombstone {
                cursor.pendingDelete = false
                cursor.deleteRejectRounds = 0
                cursor.reconciled = nil
                cursor.server = nil
                cursor.deletedAtMs = now()
                cursor.hidden = true
                spaceCounters.tombstones += 1
                tombstoned.insert(item.uuid)
            } else if let outgoing = item.outgoing {
                // BOTH baselines: updating only `server` would let the next
                // snapshot decide the field still differs from `reconciled`,
                // stamp `now` again, and win the account's LWW every round.
                cursor.reconciled = try? outgoing.serializedData()
                cursor.server = cursor.reconciled
                cursor.deleteRejectRounds = 0
                spaceCounters.pushed += 1
            }
        case .conflict:
            conflicted.insert(item.uuid)
            spaceCounters.conflicts += 1
        case .invalidMessage:
            guard isTombstone else {
                // "The server has no such row": drop the server-side triple and
                // let the next round re-create through the client_tag unique
                // index. `reconciled` survives -- it is this device's timestamp
                // history, not a statement about the server.
                cursor.entityId = nil
                cursor.version = 0
                cursor.server = nil
                break
            }
            // A rejected tombstone proves nothing: the server resolves a
            // tombstone's data type with a query OUTSIDE the commit transaction,
            // so any transient failure returns the same code as "no such row".
            // Keep the intent and re-send it unchanged; give up only after three.
            cursor.deleteRejectRounds += 1
            if cursor.deleteRejectRounds >= Self.tombstoneRejectGiveUpRounds {
                AppLogError("[phi-sync] giving up on a tombstone after \(cursor.deleteRejectRounds) rejections tag=\(String(item.entry.clientTagHash.prefix(8)))")
                cursor.pendingDelete = false
                cursor.reconciled = nil
                cursor.server = nil
                cursor.deletedAtMs = now()
                cursor.hidden = true
            }
        case .rejected(let type):
            AppLogError("[phi-sync] space commit rejected response_type=\(type) tag=\(String(item.entry.clientTagHash.prefix(8)))")
        }
        table.cursors[item.uuid] = cursor
    }

    // MARK: - Owned items: round initialization, routing, landing and publication (M3-3 section 5)

    /// At most 250 publications per kind per round: ten batches of 25 (section 5.3). Reuse
    /// maxCommitEntriesPerBatch below the server's 500-item limit. Ten sequential HTTP trips
    /// already occupy roundQueue; the cap leaves time for settings and Spaces each round.
    private static let maxOwnedCommitsPerRound = 250

    /// What one pull collected for ONE owned kind.
    private struct OwnedPullBatch {
        var arrivals: [(identity: String, payload: Data, entityId: String, version: Int64)] = []
        var tombstones: [(identity: String, entityId: String, version: Int64)] = []
        var unreadableHashes: [String] = []
        var unreadable = 0
    }

    /// Compute and cache the round's identity mappings.
    private func ownedRoundMaps() async -> OwnedOwnerMaps {
        if let ownedMapsThisRound { return ownedMapsThisRound }
        var maps = OwnedOwnerMaps()
        guard let spaceAccess else { ownedMapsThisRound = maps; return maps }
        let table = loadSpaceTable()
        for (localId, uuid) in await spaceAccess.allSpaceMappings() {
            maps.syncUuidBySpaceId[localId] = uuid
            maps.localSpaceIdBySyncUuid[uuid] = localId
        }
        // D1 assigns a constant default-Space identity absent from mapping stores. This snapshots
        // PhiSpaceLocalAccess's existing translation methods (R-D6-14(6)).
        maps.syncUuidBySpaceId[LocalStore.defaultSpaceId] = SyncableSpaces.defaultSpaceUuid
        maps.localSpaceIdBySyncUuid[SyncableSpaces.defaultSpaceUuid] = LocalStore.defaultSpaceId
        let spaces = await spaceAccess.currentSpaces()
        for space in spaces {
            // The Space's own Profile binding, for rows landed into it (review A4/A5).
            maps.localProfileIdBySpaceId[space.spaceId] = space.profileId
            // Section 4.2 rule 1: present in currentSpaces(), mapped to a syncUuid, and neither
            // hidden nor purged.
            if let uuid = maps.syncUuidBySpaceId[space.spaceId] {
                let cursor = table.cursors[uuid]
                if cursor?.hidden != true, cursor?.purgedAtMs == nil {
                    maps.eligibleSpaceUuids.insert(uuid)
                }
            }
            if maps.globalUuidByProfileId[space.profileId] == nil,
               let uuid = await spaceAccess.globalUuid(forProfileId: space.profileId) {
                maps.globalUuidByProfileId[space.profileId] = uuid
                maps.localProfileIdByGlobalUuid[uuid] = space.profileId
            }
        }
        ownedMapsThisRound = maps
        return maps
    }

    /// Initialize each registered kind once per round: one local read, one cursor-table load and
    /// tag-index construction (section 5.7(2)). Either pull or push can arrive first. A failed
    /// local read disables snapshot, diff, publication and landing without cursor writes
    /// (R-exec-3). Never treat failure as empty rows, which would tombstone every published account
    /// identity.
    private func beginOwnedRound() async {
        guard !ownedKinds.isEmpty, spaceStore != nil else { return }
        for registration in ownedKinds {
            guard !ownedRoundStarted.contains(registration.label) else { continue }
            ownedRoundStarted.insert(registration.label)
            let loaded = loadOwnedTable(registration, armsReplayOnLoss: false)
            let table = loaded.table
            // Review A2: remember a loss the store reported here. Landing may write a partial
            // table back before publication re-loads, and a non-empty file no longer reports
            // loss — publication must still arm the replay, or every cursor-less local row is
            // committed as a create over the account tree.
            if loaded.reportedLoss { ownedLossObservedAtEntry.insert(registration.label) }
            var identities: Set<String> = []
            do {
                try await registration.beginRound()
                identities = await registration.localIdentities()
            } catch {
                ownedReadFailed.insert(registration.label)
                var counters = ownedCounters[registration.label] ?? OwnedRoundCounters()
                counters.localReadFailed += 1
                ownedCounters[registration.label] = counters
                AppLogError("[phi-sync] owned-item local read failed kind=\(registration.label) "
                            + "(\(PhiSyncLog.describe(error)))")
            }
            // Seed from cursor keys plus local identities (section 5.1), then only add learned
            // identities during the round.
            var index: [String: String] = [:]
            for identity in Set(table.cursors.keys).union(identities) where !identity.isEmpty {
                index[PhiSyncEntity.clientTagHash(for: registration.clientTag(identity))] = identity
            }
            ownedTagIndices[registration.label] = index
        }
    }

    /// Load a kind's cursor table and handle loss (R-M3-3-13). Only publication enables
    /// armsReplayOnLoss (CASE 6.26), clearing the marker and arming an incomplete full drain that
    /// blocks publication until replay finishes. No extra publishBlocked flag is needed: failed
    /// recovery writes already close canPublishThisRound (R-M3-4a-103).
    /// Persist marker reset before the per-kind latch/drain flags. Reversing them could leave an
    /// old marker with a consumed latch: an empty incremental response would falsely complete
    /// replay, and an unreadable table could never rearm its latch. Both writes must be confirmed.
    ///
    /// `lost` means this call armed the replay; `reportedLoss` is what the store (or an earlier
    /// observation this round, `lossObservedEarlier`) said, independent of arming.
    private func loadOwnedTable(_ registration: OwnedKindRegistration,
                                armsReplayOnLoss: Bool,
                                lossObservedEarlier: Bool = false)
        -> (table: PhiOwnedItemTable, lost: Bool, reportedLoss: Bool) {
        let spaceTable = loadSpaceTable()
        let (table, storeReportedLoss) = registration.store
            .load(hadRecords: spaceTable[keyPath: registration.flags.hadRecords])
        // Review A2: a loss observed at round entry stands even if landing has since written a
        // non-empty file — that file is partial, and the account tree must be replayed.
        let reportedLoss = storeReportedLoss || lossObservedEarlier
        ownedTables[registration.label] = table
        guard reportedLoss else {
            // Unlike the permanent Space latch, the per-kind latch rearms after a successful load
            // returns published cursors (A2). Never rearm after save: a permanently unreadable file
            // could repeatedly lose/replay/rebuild/save and trigger a full-type replay every round.
            if table.cursors.values.contains(where: { !$0.entityId.isEmpty }),
               spaceTable[keyPath: registration.flags.replayedForEmptyTable] {
                mutateSpaceTable { $0[keyPath: registration.flags.replayedForEmptyTable] = false }
            }
            return (table, false, reportedLoss)
        }
        guard armsReplayOnLoss else { return (table, false, reportedLoss) }
        // Use this kind's one-shot latch (A2), never the permanent Space didReplayForEmptyTable
        // latch, which may already have been consumed before the first bookmark/pin file loss.
        guard !spaceTable[keyPath: registration.flags.replayedForEmptyTable] else {
            return (table, true, reportedLoss)
        }
        // First persist the nil marker. Failure leaves the latch/drain flags unchanged, reports
        // cursorSaveFailed and closes publication, so next round can retry. Update the engine
        // property because this helper also runs outside pull; the write helper counts failures.
        guard persistStoredMarker(nil) else {
            roundOutcome = .cursorSaveFailed
            return (table, false, reportedLoss)
        }
        // After confirmed marker reset, persist the per-kind latch and drain flags. Failure rolls
        // the mirror back (R-M3-4a-83), leaving reset-marker/unconsumed-latch for retry. Repeating
        // step 1 is an idempotent no-write success (R-M3-4a-103).
        guard mutateSpaceTable({ updated in
            updated[keyPath: registration.flags.replayedForEmptyTable] = true
            updated.hasDrainedFullReplay = false
            updated.drainInProgress = true
        }) else {
            roundOutcome = .cursorSaveFailed
            return (table, false, reportedLoss)
        }
        // Both failure branches return (table, false): lost=true means this attempt successfully
        // armed replay. Log only after both writes succeed.
        AppLogWarn("[phi-sync] owned-item cursor table lost kind=\(registration.label); "
                   + "replaying data type \(PhiSyncEntity.dataTypeID) once")
        return (table, true, reportedLoss)
    }

    /// Persist the kind's table and maintain per-kind flags. HadRecords becomes true on the first
    /// persisted cursor with a nonempty entityId. Reset the replay latch only after a successful
    /// load, never save, to avoid endless replay of permanently unreadable files.
    /// Return whether persistence succeeded (R-M3-4a-83). Retirement is a successful no-op: failure
    /// means an invoked save reported failure, not an early exit (R-M3-4a-16).
    @discardableResult
    private func writeOwnedTable(_ registration: OwnedKindRegistration,
                                 _ table: PhiOwnedItemTable) -> Bool {
        // Retirement is an early return, not a persistence failure (R-M3-4a-16).
        guard !isStopped else { return true }
        ownedTables[registration.label] = table
        // Count an invoked save returning failure inside the write boundary (section 2.5(4)).
        // ownedTables is updated first, so its mirror can temporarily lead disk; B-2 blocks
        // publication this round and reloads next round.
        guard registration.store.save(table) else {
            cursorSaveFailures += 1
            return false
        }
        let hasPublished = table.cursors.values.contains { !$0.entityId.isEmpty }
        guard hasPublished else { return true }
        // Update per-kind flags only after save (section 2.5(7)). HadRecords records that a
        // published cursor was actually persisted. Prematurely setting it on failure could
        // invalidate later loss detection and prevent the full replay needed to restore the account
        // tree.
        mutateSpaceTable { $0[keyPath: registration.flags.hadRecords] = true }
        return true
    }

    /// Section 5.2 steps 2-5: route, decrypt, derive the tag, compare, then place. A supplied
    /// decoded envelope came from fallback routing and must not be decrypted twice.
    private func routeOwnedEntity(_ registration: OwnedKindRegistration,
                                  _ entity: PhiRemoteEntity,
                                  key: SymmetricKey,
                                  decoded: Phi_PhiEntity?,
                                  into batches: inout [String: OwnedPullBatch]) {
        let shortHash = String(entity.clientTagHash.prefix(8))
        var batch = batches[registration.label] ?? OwnedPullBatch()
        defer { batches[registration.label] = batch }

        // Handle tombstones before decryption: they have no ciphertext. Misclassifying them as
        // unreadable permanently loses remote deletions once the marker passes their page. The
        // settings branch's deletion guard does not protect this route (V35).
        guard !entity.deleted else {
            guard let identity = ownedTagIndices[registration.label]?[entity.clientTagHash] else {
                AppLogInfo("[phi-sync] ignoring an owned-item tombstone for an unknown tag "
                           + "hash=\(shortHash) kind=\(registration.label)")
                return
            }
            batch.tombstones.append((identity: identity, entityId: entity.entityId,
                                     version: entity.version))
            return
        }

        // Step 3: decrypt.
        let payload: Phi_PhiEntity
        if let decoded {
            payload = decoded
        } else {
            do {
                payload = try PhiEntityCodec.decrypt(entity.ciphertext, key: key)
            } catch {
                AppLogWarn("[phi-sync] cannot open an owned-item entity tag=\(shortHash) "
                           + "kind=\(registration.label) ciphertext_bytes=\(entity.ciphertext.count) "
                           + "(\(PhiSyncLog.describe(error)))")
                batch.unreadableHashes.append(entity.clientTagHash)
                batch.unreadable += 1
                return
            }
        }

        // Step 4: ignore payloads that do not belong to this kind.
        guard let identity = registration.identity(payload) else { return }

        // Step 5: the payload identity must hash to its incoming tag (section 2.5). Do not compare
        // ownership, since cross-Space moves are valid. Tombstones already returned and have no
        // payload from which to derive a tag.
        let expected = PhiSyncEntity.clientTagHash(for: registration.clientTag(identity))
        guard expected == entity.clientTagHash else {
            AppLogError("[phi-sync] an owned-item payload does not hash back to its "
                        + "tag=\(shortHash) kind=\(registration.label)")
            batch.unreadableHashes.append(entity.clientTagHash)
            batch.unreadable += 1
            return
        }
        guard let bytes = try? payload.serializedData() else { return }
        batch.arrivals.append((identity: identity, payload: bytes,
                               entityId: entity.entityId, version: entity.version))
        // Learn immediately so later pages in this drain can route the identity's tombstone.
        ownedTagIndices[registration.label, default: [:]][entity.clientTagHash] = identity
    }

    /// Persist unreadable-tag observations alongside durable marker advancement, as
    /// flushSpaceObservations does, so a later error cannot discard learned quarantine state.
    private func flushOwnedObservations(_ batches: [String: OwnedPullBatch]) {
        let hashes = batches.values.flatMap(\.unreadableHashes)
        guard !hashes.isEmpty else { return }
        let seenAt = now()
        mutateSpaceTable { table in
            for hash in hashes { table.unreadableTagHashes[hash] = seenAt }
        }
    }

    /// Durably park received owned entities when applyOwnedKind cannot read local rows. Under B-2,
    /// pull's catch no longer calls this: completed pages have already landed and a failed
    /// getUpdates page never arrived.
    /// Use the existing cursor channels rather than relying on server redelivery after marker
    /// advancement: live payloads use pendingApply/pendingOwnerUuid; tombstones use
    /// pendingTombstone. Harvest server identity/version first for both (A6), including newly
    /// created cursors, or later local deletion and editing would misclassify them as never
    /// published. Next round includes these channels in its work set.
    /// Unlike resetting the whole data type, this preserves incremental arrivals without involving
    /// settings and unrelated kinds. ownedReadFailed suppresses outbound snapshot/diff/publication,
    /// not durable accounting of bytes already received.
    private func parkUndeliveredOwnedEntities(_ batches: [String: OwnedPullBatch],
                                              reason: String) {
        guard !isStopped, spaceStore != nil else { return }
        for registration in ownedKinds {
            guard let batch = batches[registration.label],
                  !batch.arrivals.isEmpty || !batch.tombstones.isEmpty else { continue }
            var table = ownedTables[registration.label] ?? PhiOwnedItemTable()
            for item in batch.tombstones {
                var cursor = table.cursors[item.identity] ?? PhiOwnedItemCursor()
                harvestTriple(into: &cursor, entityId: item.entityId, version: item.version)
                cursor.pendingTombstone = true
                table.cursors[item.identity] = cursor
            }
            for item in batch.arrivals {
                var cursor = table.cursors[item.identity] ?? PhiOwnedItemCursor()
                let known = cursor.version
                harvestTriple(into: &cursor, entityId: item.entityId, version: item.version)
                // Apply the version-based section 5.6 L2 guard here too: do not park a replay older
                // than the local tombstone, which would recreate a deleted row next round. Still
                // harvest its server identity/version for the pending tombstone (A6).
                if cursor.deletedAtMs == nil || item.version > known {
                    cursor.pendingApply = item.payload
                    cursor.pendingOwnerUuid = registration.owners(item.payload).first
                }
                table.cursors[item.identity] = cursor
            }
            AppLogWarn("[phi-sync] parking what the shared marker already consumed kind="
                       + "\(registration.label) reason=\(reason) "
                       + "parked=\(batch.arrivals.count) tombstones=\(batch.tombstones.count)")
            writeOwnedTable(registration, table)
        }
    }

    /// Retry parked claims once at the start of owned processing in every round type (section 3 /
    /// R-exec-10). Pure push rounds also need matches before snapshot minting and absence
    /// detection; otherwise a settings edit could delete the account identity and remint the same
    /// row. Use existing pendingApply and freshly computed matches, without adding persistent
    /// window/mint/dedup state (section 3.5).
    private func retryParkedOwnedClaims(_ registration: OwnedKindRegistration,
                                        maps: OwnedOwnerMaps) async {
        guard !isStopped, !ownedParkedRetryDone.contains(registration.label) else { return }
        ownedParkedRetryDone.insert(registration.label)
        guard !ownedReadFailed.contains(registration.label) else { return }
        var table = ownedTables[registration.label] ?? PhiOwnedItemTable()
        var parked: [String: ParkedOwnedItem] = [:]
        for (identity, cursor) in table.cursors {
            guard let payload = cursor.pendingApply else { continue }
            parked[identity] = ParkedOwnedItem(payload: payload,
                                               pendingOwnerUuid: cursor.pendingOwnerUuid)
        }
        guard !parked.isEmpty else { return }
        let result = await registration.retryParkedClaims(parked, maps)
        guard !result.persisted.isEmpty else { return }
        var changed = false
        for identity in result.persisted {
            guard var cursor = table.cursors[identity] else { continue }
            // Only a write-back retry can clear parking here: its pendingApply equals an already
            // landed reconciled baseline, leaving no content to land after identity claim. A
            // genuinely incoming entity blocked by an import lock still has unlanded field merges;
            // claim writes identity only. Clearing that payload would lose remote fields
            // permanently after marker advancement and publish the whole local row instead (section
            // 6.2). Keeping it is safe because pendingApply excludes publication until landing.
            guard cursor.reconciled == cursor.pendingApply else { continue }
            cursor.pendingApply = nil
            cursor.pendingOwnerUuid = nil
            table.cursors[identity] = cursor
            changed = true
        }
        guard changed else { return }
        writeOwnedTable(registration, table)
    }

    /// Single incoming write point for the A6 server triple. A nonempty entityId also resets
    /// consecutive rekey failures (F-PK-4), matching applied commits: an identity recovered from an
    /// incoming update no longer needs repair, and old failures must not consume a future repair
    /// budget. Empty IDs change nothing, avoiding demotion to an unversioned create. Take
    /// max(version), since pagination and parked retries can harvest the same identity repeatedly.
    private func harvestTriple(into cursor: inout PhiOwnedItemCursor,
                               entityId: String, version: Int64) {
        if !entityId.isEmpty {
            cursor.entityId = entityId
            cursor.rekeyRejectRounds = nil
        }
        cursor.version = max(cursor.version, version)
    }

    /// Owned-kind incoming landing: apply before baseline updates is the section 4.5 invariant.
    private func applyOwnedKind(_ registration: OwnedKindRegistration,
                                batch: OwnedPullBatch, maps: OwnedOwnerMaps) async {
        guard !isStopped else { return }
        var counters = ownedCounters[registration.label] ?? OwnedRoundCounters()
        counters.pulled += batch.arrivals.count + batch.tombstones.count
        counters.unreadable += batch.unreadable
        counters.tombstones += batch.tombstones.count
        ownedCounters[registration.label] = counters
        // A round-start local read failure suppresses outbound work (R-exec-3), but must not
        // discard this incoming batch. Persist it through the shared parked channel so later
        // successful reads can land changes even after the marker has passed their page.
        guard !ownedReadFailed.contains(registration.label) else {
            parkUndeliveredOwnedEntities([registration.label: batch], reason: "local-read-failed")
            return
        }

        var table = ownedTables[registration.label] ?? PhiOwnedItemTable()
        // Work set: incoming tombstones plus every persisted pendingTombstone cursor (section 5.6).
        // The shared marker may already prevent server redelivery.
        var tombstoned = Set(batch.tombstones.map(\.identity))
        for (identity, cursor) in table.cursors where cursor.pendingTombstone {
            tombstoned.insert(identity)
        }
        // Harvest every incoming entity's server triple, including tombstones (A6). Keep
        // tombstoneTriples for the parking paths that create new cursors; this loop updates
        // existing cursors only, since T1 does not create cursors for unknown tombstones.
        var tombstoneTriples: [String: (entityId: String, version: Int64)] = [:]
        for item in batch.tombstones {
            let previous = tombstoneTriples[item.identity]
            tombstoneTriples[item.identity] =
                (entityId: item.entityId.isEmpty ? (previous?.entityId ?? "") : item.entityId,
                 version: max(item.version, previous?.version ?? 0))
            guard var cursor = table.cursors[item.identity] else { continue }
            harvestTriple(into: &cursor, entityId: item.entityId, version: item.version)
            table.cursors[item.identity] = cursor
        }
        // Before plan, filter live arrivals against deletedAtMs cursors using server version
        // (section 5.6 L2). plan does not check that cursor field and could otherwise move/update a
        // deleted row. A newer live version is a legitimate post-tombstone resurrection
        // (R-M3-3-23); an equal/older version is replay and must not restore the row. The server
        // stores only the latest entity version; field timestamps are not a substitute for this
        // ordering.
        var arrivals = batch.arrivals
        var resurrecting: Set<String> = []
        var replayedAfterDelete = 0
        if arrivals.contains(where: { table.cursors[$0.identity]?.deletedAtMs != nil }) {
            var kept: [(identity: String, payload: Data, entityId: String, version: Int64)] = []
            for item in arrivals {
                guard var cursor = table.cursors[item.identity],
                      cursor.deletedAtMs != nil else {
                    kept.append(item)
                    continue
                }
                // Harvest in both branches (A6), but compare against the version captured before
                // harvesting.
                let known = cursor.version
                harvestTriple(into: &cursor, entityId: item.entityId, version: item.version)
                table.cursors[item.identity] = cursor
                guard item.version > known else {
                    replayedAfterDelete += 1
                    continue
                }
                resurrecting.insert(item.identity)
                kept.append(item)
            }
            arrivals = kept
        }
        counters.supersededByDelete += replayedAfterDelete
        ownedCounters[registration.label] = counters
        var parked: [String: ParkedOwnedItem] = [:]
        for (identity, cursor) in table.cursors {
            guard let payload = cursor.pendingApply else { continue }
            parked[identity] = ParkedOwnedItem(payload: payload,
                                               pendingOwnerUuid: cursor.pendingOwnerUuid)
        }
        // landsEmptyBatch adds the empty-page path only for URL rules, allowing their M2
        // convergence pass (R-M3-4a-99/56). Other kinds retain their early return.
        guard !arrivals.isEmpty || !tombstoned.isEmpty || !parked.isEmpty
                || registration.landsEmptyBatch else {
            // Persist triples harvested from L2-rejected replays. This version may never be
            // delivered again, and the local pending tombstone needs it for publication.
            if replayedAfterDelete > 0 { writeOwnedTable(registration, table) }
            return
        }

        // R2.1: fold every landed owned-item stamp into logical time before planning stamps the
        // local side of the merge. Envelope bytes are decoded again inside `plan`; observing
        // here keeps the ordering explicit rather than threading the clock into the pure module.
        for payload in arrivals.map(\.payload) + parked.values.map(\.payload) {
            guard let envelope = try? Phi_PhiEntity(serializedBytes: payload) else { continue }
            observeStamps(of: envelope)
        }
        // Read `maxSeen` BEFORE issuing the round's stamp: `hlcNow()` advances it, and AM-1's
        // no-baseline floor is the logical time this round started from, not the stamp it just
        // issued.
        let planHlcMax = hlcClock.maxSeen
        let planNow = hlcNow()

        let output = await registration.plan(
            OwnedPlanInput(arrivals: arrivals.map {
                               (payload: $0.payload, entityId: $0.entityId, version: $0.version)
                           },
                           parked: parked, table: table, maps: maps, tombstoned: tombstoned,
                           now: planNow, hlcMax: planHlcMax))
        counters.adopted += output.adopted
        counters.unmatchedFolders += output.unmatchedFolders
        counters.unmergeablePairs += output.unmergeablePairs
        // Only URL-rule planning reports normalized (section 13.2); other kinds remain zero.
        counters.normalized += output.normalized
        counters.refused += output.plan.refused
        counters.supersededByDelete += output.plan.supersededByDelete
        counters.scopeMismatch = counters.scopeMismatch || output.scopeMismatch
        ownedMustRepublish[registration.label] = output.mustRepublish
        // Union deferred owners across every pull in this round (section 5.3).
        ownedDeferredOwners[registration.label, default: []]
            .formUnion(output.deferredOwners)

        // Update existing cursors only (P5). Plan harvests before refusing malformed payloads, so
        // constructing a cursor for every harvested identity would let repeated invalid arrivals
        // grow the cursor table indefinitely.
        for (identity, harvested) in output.plan.harvest {
            guard var cursor = table.cursors[identity] else { continue }
            harvestTriple(into: &cursor, entityId: harvested.entityId,
                          version: harvested.version)
            table.cursors[identity] = cursor
        }

        /// Harvest A6 data into newly created cursors. The P5 loop above updates existing cursors
        /// only, so landing and both owner/import-lock parking paths must initialize server
        /// identity/version separately. Otherwise the consumed version will never replay and the
        /// cursor persists as never published. Live triples come from plan.harvest; tombstones come
        /// from tombstoneTriples.
        func harvestServerTriple(into cursor: inout PhiOwnedItemCursor, _ identity: String) {
            guard let triple = output.plan.harvest[identity] ?? tombstoneTriples[identity] else {
                return
            }
            harvestTriple(into: &cursor, entityId: triple.entityId, version: triple.version)
        }

        let outcome = await registration.land(
            OwnedLandingInput(steps: output.plan.steps, table: table, maps: maps,
                              claimedLocalIds: output.claimedLocalIds,
                              // D30 M2 data channels (8b-2); bookmark and pin landing ignores them.
                              preLandingSignatures: output.plan.preLandingSignatures,
                              atRestIdentities: output.atRestIdentities,
                              // C-15: convergence gating applies only to section 8.4.3 step 2.
                              convergeAllowed: ownedItemsPublishAllowed,
                              // Pass rebaselined explicitly because cursor write-back occurs only
                              // after landing (R-M3-4a-97).
                              rebaselined: output.plan.rebaselined))
        guard !isStopped else { return }
        // Variant reminting runs inside the landing batch; take its count from the outcome (section
        // 7.2 / A11).
        counters.relineaged += outcome.relineaged
        // Count M2 losers actually soft-deleted at the transaction tail (section 13.2 /
        // R-M3-4a-54).
        counters.collapsed += outcome.collapsed
        // Count move operations actually retained in the landing batch (section 13.2 / ruling 3).
        counters.ownerMoved += outcome.ownerMoved
        // transferred and the section 13.3 deletion count are evaluated transactionally. Per-unit
        // LWW needs max(winner row stamp, effective account stamp), neither of which the plan
        // closure owns (ruling 9).
        counters.transferred += outcome.transferred
        counters.supersededByDelete += outcome.supersededByDelete
        // The kind's plan closure counts yield_no_partner at its decision point (section 13.2 /
        // R-M3-4a-75(3)).
        counters.yieldNoPartner += output.yieldNoPartner
        // Collect newly created rows for one round-end favicon submission (section 8.2 / Task 10).
        faviconCandidatesThisRound.append(contentsOf: outcome.createdRows)
        faviconPinCandidatesThisRound.append(contentsOf: outcome.createdPins)

        var spaceTable = loadSpaceTable()
        var spaceTableChanged = false
        for identity in outcome.landed {
            var cursor = table.cursors[identity] ?? PhiOwnedItemCursor()
            harvestServerTriple(into: &cursor, identity)
            if outcome.deleted.contains(identity) {
                // Section 5.6 T1-T3: clear pending work and stamp deletedAtMs so this round's diff
                // cannot echo a remote deletion as a local tombstone.
                cursor.reconciled = nil
                cursor.server = nil
                cursor.deletedAtMs = now()
                cursor.pendingDelete = false
            } else {
                if let bytes = outcome.reconciled[identity] { cursor.reconciled = bytes }
                // The server baseline is always remote bytes, never the merge result, which the
                // server may not yet hold (section 4.5).
                if let server = output.serverBytes[identity] { cursor.server = server }
                // Clear deletedAtMs only after a legitimate L2 resurrection lands. Otherwise rule
                // 3b sees a live row plus tombstone every round and repeatedly republishes with
                // conflict/retry churn (section 5.6).
                if resurrecting.contains(identity), cursor.deletedAtMs != nil {
                    cursor.deletedAtMs = nil
                    counters.resurrected += 1
                }
            }
            cursor.pendingApply = nil
            cursor.pendingOwnerUuid = nil
            cursor.pendingTombstone = false
            // Only landing can tell whether a split partner resolved (section 7.4). Empty clears
            // the wait, allowing future local unlink publication; nonempty preserves the baseline
            // while waiting.
            if let waiting = outcome.pendingPartnerLineages[identity] {
                cursor.pendingPartnerLineage = waiting.isEmpty ? nil : waiting
            }
            table.cursors[identity] = cursor
            // Successful landing also proves this tag readable. Clear quarantine or a transient
            // decryption failure would permanently deny publication (section 4.5).
            let hash = PhiSyncEntity.clientTagHash(for: registration.clientTag(identity))
            if spaceTable.unreadableTagHashes.removeValue(forKey: hash) != nil {
                spaceTableChanged = true
            }
            counters.applied += 1
        }
        // After a successful M1 claim, remove the retired locally minted cursor (section 8.4.2(4) /
        // R-M3-4a-53). Its never-published predicate guarantees no server state is lost. Do not
        // remove it after rolled-back landing, or the surviving local identity could publish a
        // blind create. Skip retired==identity too, which would delete the baseline just written by
        // an idempotent rekey.
        for (identity, retired) in output.retiredIdentities
        where outcome.landed.contains(identity) && retired != identity {
            table.removeCursor(identity: retired)
        }
        // Park while the owner remains unlanded (section 4.4(4)), harvesting the server triple even
        // when this creates a new cursor (A6). P5's earlier loop updates existing cursors only.
        // Without identity/version, this consumed arrival can never repair itself: local deletion
        // is suppressed as never published, while editing sends a baseVersion-zero create that
        // overwrites account data (R-exec-1; reproduced on Mac B build 822). This mirrors Space
        // fallback-B parking.
        for (identity, item) in output.plan.parked {
            var cursor = table.cursors[identity] ?? PhiOwnedItemCursor()
            harvestServerTriple(into: &cursor, identity)
            cursor.pendingApply = item.payload
            cursor.pendingOwnerUuid = item.pendingOwnerUuid
            table.cursors[identity] = cursor
        }
        // Persist payload-free tombstones parked by scope mismatch (section 7.3). They produce no
        // plan step or landing outcome, so omitting pendingTombstone would silently lose the
        // deletion after marker advancement despite a healthy-looking harvested cursor.
        for identity in output.plan.parkedTombstones {
            var cursor = table.cursors[identity] ?? PhiOwnedItemCursor()
            harvestServerTriple(into: &cursor, identity)
            cursor.pendingTombstone = true
            table.cursors[identity] = cursor
        }
        // Section 8.4.4(alpha)(ii) yields deletion to local intent (R-M3-4a-61 / ruling 6). Keep
        // the row, clear both baselines/pending work, and retain deletedAtMs: it is the sole
        // round-end rule-3b reentry condition and L2 replay guard (RR5-3). Do not classify as
        // outcome.deleted or call noteDeletedRows. Harvest the tombstone version for the later
        // resurrection's base_version.
        for identity in output.plan.yieldedTombstones {
            var cursor = table.cursors[identity] ?? PhiOwnedItemCursor()
            harvestServerTriple(into: &cursor, identity)
            cursor.reconciled = nil
            cursor.server = nil
            cursor.deletedAtMs = now()
            cursor.pendingTombstone = false
            cursor.pendingApply = nil
            cursor.pendingOwnerUuid = nil
            cursor.pendingDelete = false
            table.cursors[identity] = cursor
        }
        // A transaction-time source change prevented both transfer and delete(X) (R-M3-4a-102 /
        // ruling 11). Account exactly as parkedTombstones: harvest identity/version and set
        // pendingTombstone without changing rows, baselines or deletedAtMs.
        for identity in outcome.deferredTombstones {
            assert(!outcome.landed.contains(identity) && !outcome.deleted.contains(identity),
                   "a deferred tombstone must be in neither landed nor deleted")
            var cursor = table.cursors[identity] ?? PhiOwnedItemCursor()
            harvestServerTriple(into: &cursor, identity)
            cursor.pendingTombstone = true
            table.cursors[identity] = cursor
        }
        // Import-lock parking also creates cursors as needed (sections 4.9(3)/5.6 T4).
        for identity in outcome.parked {
            var cursor = table.cursors[identity] ?? PhiOwnedItemCursor()
            harvestServerTriple(into: &cursor, identity)
            if let payload = output.plan.steps.first(where: { $0.identity == identity })?.payload {
                cursor.pendingApply = payload
            }
            if tombstoned.contains(identity) { cursor.pendingTombstone = true }
            table.cursors[identity] = cursor
        }
        // Refusal neither lands nor parks nor creates cursors (CASE 6.6b / 6.11b).
        counters.refused += outcome.refused.count
        // A9 cancelled the pending local deletion.
        for identity in output.plan.cancelledDeletes {
            guard var cursor = table.cursors[identity] else { continue }
            cursor.pendingDelete = false
            cursor.deleteDecidedAtMs = 0
            table.cursors[identity] = cursor
        }
        // Section 7.4 also updates a partner with no incoming entity this round when landing links
        // its reverse side in the same transaction. Otherwise peers display different split pairs
        // until another local change. Exclude all four outcome categories: landed is handled above,
        // and parked/refused/unverified identities must not clear waits without proven local state.
        // Incorrectly clearing pendingPartnerLineage would make next round interpret a valid remote
        // split as a local unlink.
        for (identity, waiting) in outcome.pendingPartnerLineages
        where !outcome.landed.contains(identity) && !outcome.parked.contains(identity)
            && !outcome.refused.contains(identity) {
            guard var cursor = table.cursors[identity] else { continue }
            let updated: String? = waiting.isEmpty ? nil : waiting
            guard cursor.pendingPartnerLineage != updated else { continue }
            cursor.pendingPartnerLineage = updated
            table.cursors[identity] = cursor
        }
        // Adopt newer baseline stamps even when equal values require no landing steps
        // (OwnedItemPlan.rebaselined). An older baseline could otherwise let a later, older
        // conflicting value win. This respects apply-before-baseline: these identities have nothing
        // to apply. Exclude parked, refused and landed identities, whose own paths handle
        // write-back.
        for (identity, bytes) in output.plan.rebaselined {
            guard var cursor = table.cursors[identity], cursor.reconciled != nil,
                  cursor.pendingApply == nil, !cursor.pendingTombstone,
                  !outcome.landed.contains(identity), !outcome.parked.contains(identity),
                  !outcome.refused.contains(identity) else { continue }
            cursor.reconciled = bytes
            // server is the fetched remote entity, never merged bytes (section 4.5).
            if let server = output.serverBytes[identity] { cursor.server = server }
            table.cursors[identity] = cursor
        }
        // For locally winning identities that produced no landing step, refresh server so the
        // durable server!=reconciled predicate can detect the disagreement and republish. Change
        // only server, which describes account state; reconciled describes successfully landed
        // local state (section 4.5).
        for identity in output.mustRepublish where !outcome.landed.contains(identity) {
            guard var cursor = table.cursors[identity], cursor.reconciled != nil,
                  cursor.pendingApply == nil, !cursor.pendingTombstone,
                  !outcome.parked.contains(identity), !outcome.refused.contains(identity),
                  let server = output.serverBytes[identity], cursor.server != server else {
                continue
            }
            cursor.server = server
            table.cursors[identity] = cursor
        }
        if spaceTableChanged { writeSpaceTable(spaceTable) }
        ownedCounters[registration.label] = counters
        writeOwnedTable(registration, table)
    }

    /// Owned publication shares the Space gate (PR6). The coordinator queues
    /// setSpaceSyncEnabled(false) while pairing; the engine cannot directly read MainActor
    /// ProfilePairingGate state. Also require hasDrainedFullReplay: a newly joined device must
    /// download the account tree before minting/publishing local identities, or D10 adoption
    /// becomes permanently ineligible.
    private var ownedItemsPublishAllowed: Bool {
        guard spaceSectionEnabled, spaceStore != nil, !ownedKinds.isEmpty else { return false }
        return loadSpaceTable().hasDrainedFullReplay
    }

    private func pushOwnedItems(retryOnConflict: Bool) async {
        // Match spaceLive, including spaceAccess. Without it, all identity mappings would be empty
        // and publication would proceed with unresolved ownership.
        guard !isStopped, canPublishThisRound, !ownedKinds.isEmpty, spaceSectionEnabled,
              spaceStore != nil, spaceAccess != nil else { return }
        await beginOwnedRound()
        let maps = await ownedRoundMaps()
        // Retry parked claims first for every round type. Pull already did so before landing;
        // ownedParkedRetryDone keeps it once per round.
        for registration in ownedKinds {
            await retryParkedOwnedClaims(registration, maps: maps)
        }
        for registration in ownedKinds {
            await publishOwnedKind(registration, maps: maps, retryOnConflict: retryOnConflict)
        }
    }

    /// Publish one kind: snapshot, deletion diff, two ordered slices, batching, write-back.
    /// onlyIdentities limits conflict retries so one conflict does not retransmit hundreds of
    /// unrelated entities.
    private func publishOwnedKind(_ registration: OwnedKindRegistration,
                                  maps: OwnedOwnerMaps,
                                  retryOnConflict: Bool,
                                  onlyIdentities: Set<String>? = nil) async {
        guard !isStopped, canPublishThisRound else { return }
        // A failed round-start read suppresses the entire snapshot/diff/publication section
        // (R-exec-3), not just some entries.
        guard !ownedReadFailed.contains(registration.label) else { return }
        guard ownedItemsPublishAllowed else { return }
        // Snapshot save-failure count before this load. Test whether this kind's replay arming just
        // failed, not whether any earlier kind failed. A global check would suppress later kinds'
        // publication housekeeping, including pendingLocalEdit clearing and rule-3b rechecks,
        // contrary to section 2.5(6). The round-entry canPublishThisRound prerequisite is separate
        // (R-M3-4a-103).
        let failuresBeforeLoad = cursorSaveFailures
        let loaded = loadOwnedTable(
            registration, armsReplayOnLoss: true,
            lossObservedEarlier: ownedLossObservedAtEntry.contains(registration.label))
        guard !loaded.lost else { return }
        // If either replay-arming write failed, loadOwnedTable returns lost=false and the earlier
        // guards would allow publication against an empty table. Stop here without publishing or
        // recreating its file, preserving loss detection next round. Rebuilding the file would
        // prevent the latch from ever arming and permanently lose full replay (R-M3-4a-103).
        guard cursorSaveFailures == failuresBeforeLoad else { return }
        var table = loaded.table
        var counters = ownedCounters[registration.label] ?? OwnedRoundCounters()

        // Snapshot using a doctored table copy (section 7.4 / P4): clear genuinely removed split
        // partners when no pendingPartnerLineage remains, and stamp removals with this round's now
        // so LWW propagates the unlink. Preserve unresolved partners; publication still compares
        // against the real table. Read the clock once for both doctoring and snapshot, since test
        // clocks can advance on every read.
        // R2.1: the stamping clock is the HYBRID one. Read `maxSeen` first, since `hlcNow()`
        // advances it and AM-1's no-baseline floor is the round's starting logical time.
        let roundHlcMax = hlcClock.maxSeen
        let roundNow = hlcNow()
        let doctored = await doctoredOwnedTable(registration, table, maps: maps, now: roundNow)
        let snapshot = await registration.snapshot(doctored, maps, roundNow, roundHlcMax)
        counters.excludedUnmappedOwner +=
            snapshot.skippedUnmappedOwner + snapshot.skippedIneligibleOwner
        // Scope mismatch suppresses publication in every round type (sections 7.3/11.2), including
        // pure pushes with no plan execution. Collect its diagnostic from the snapshot too.
        counters.scopeMismatch = counters.scopeMismatch || snapshot.scopeMismatch

        // A12: refresh ownerUuid for every existing cursor represented in the snapshot, including
        // entries excluded by this round's slice budget.
        for (identity, owner) in snapshot.ownerUuids {
            guard var cursor = table.cursors[identity], cursor.ownerUuid != owner else { continue }
            cursor.ownerUuid = owner
            table.cursors[identity] = cursor
        }

        // Section 4.7 deletion diff uses allSyncIds()/allPinRows(), not the outbound snapshot
        // (R-exec-4). Unpublished orphan-root rows must not be mistaken for deletions.
        let diff: OwnedItemTombstoneResult
        do {
            // HLC, not wall clock: the `nowMs` argument becomes `cursor.deleteDecidedAtMs`, and
            // A9 compares that field against an LWW LOCATION STAMP
            // (`SyncableOwnedItems.plan`). Leaving it on wall clock while stamps move to the
            // hybrid clock would make every inbound entity look newer than the deletion on an
            // account whose logical time has run ahead of wall clock, and A9 would cancel every
            // local delete.
            diff = try await registration.tombstones(table, maps, hlcNow())
        } catch {
            counters.localReadFailed += 1
            ownedReadFailed.insert(registration.label)
            ownedCounters[registration.label] = counters
            AppLogError("[phi-sync] owned-item diff domain unavailable kind=\(registration.label) "
                        + "(\(PhiSyncLog.describe(error)))")
            return          // Do not write any cursor-table bytes.
        }
        for (identity, cursor) in diff.cursorUpdates { table.cursors[identity] = cursor }

        // Finalize an unsendable pendingDelete lacking entityId/version locally and stamp
        // deletedAtMs, rather than repeatedly submitting an entry the server must reject (section
        // 9.1 second gate).
        for (identity, var cursor) in table.cursors where cursor.pendingDelete {
            guard cursor.entityId.isEmpty || cursor.version == 0 else { continue }
            cursor.pendingDelete = false
            cursor.reconciled = nil
            cursor.server = nil
            cursor.deletedAtMs = now()
            table.cursors[identity] = cursor
        }

        // Recheck section 8.4.4(ii) rule-3b admission on every publication round for yielding kinds
        // only (ruling 7 / RR9-7). Key this on durable cursor state, not this round's
        // yieldedTombstones, because conflicts, transport failures and crashes can defer
        // publication into later rounds.
        // The domain is deletedAtMs present, a live local row, and reconciled nil
        // (RR10-2/11-4/12-3). The third condition excludes legitimately landed resurrections after
        // parking. Do not replace it with pendingLocalEdit or unpublished: yielding already cleared
        // both baselines, making that test permanently false.
        var yieldWithheld: Set<String> = []
        if registration.tombstoneYieldsToLocalEdits {
            let liveIdentities = await registration.localIdentities()
            let spaceCursors = loadSpaceTable().cursors
            for identity in table.cursors.keys.sorted() {
                guard let cursor = table.cursors[identity], cursor.deletedAtMs != nil,
                      cursor.reconciled == nil, liveIdentities.contains(identity) else { continue }
                // Snapshot membership proves both owner gates and absence of pending work. An
                // admitted identity follows existing rule 3b into liveCandidates with
                // cursor.version as base_version; no additional action is needed.
                if snapshot.entities[identity] != nil { continue }
                // Without a usable server triple, withhold this identity without writes (RR13-6).
                // Do not test pendingDelete: yielding already cleared all pending flags, which
                // would make revocation unreachable.
                guard !cursor.entityId.isEmpty, cursor.version > 0 else {
                    yieldWithheld.insert(identity)
                    continue
                }
                // Revoke the yield only when the target Space cursor is actually hidden or purged:
                // the rule should disappear with its Space. All other causes, including unresolved
                // mappings, unloaded Space lists or newly pending work, retain the row, deletedAtMs
                // and pendingLocalEdit unchanged, with no tombstone or rule-3b publication this
                // round. Reevaluate next round.
                guard let owner = cursor.ownerUuid, let spaceCursor = spaceCursors[owner],
                      spaceCursor.hidden || spaceCursor.purgedAtMs != nil else {
                    yieldWithheld.insert(identity)
                    continue
                }
                // Reuse registration.land's existing delete-to-hardDeleteURLRule translation
                // instead of adding another registration member. Generic publication need not
                // depend on PhiURLRuleLocalAccess, matching the withdrawal of deleteGuard in
                // R-M3-4a-84.
                let revoked = await registration.land(
                    OwnedLandingInput(steps: [OwnedItemApplyStep(identity: identity, kind: .delete,
                                                                 newParentUuid: nil, newRank: nil,
                                                                 payload: nil)],
                                      table: table, maps: maps))
                yieldWithheld.insert(identity)
                guard revoked.landed.contains(identity) else { continue }
                var updated = cursor
                updated.reconciled = nil
                updated.server = nil
                updated.deletedAtMs = now()
                updated.pendingDelete = false
                table.cursors[identity] = updated
            }
        }

        // Build two slices in opposite dependency orders (section 5.3).
        var budget = Self.maxOwnedCommitsPerRound
        // The third conjunct protects identities already pendingDelete before this round, which may
        // have no new cursorUpdate but still enter through the first two conditions (R-M3-4a-84 /
        // ruling 5).
        let deleteCandidates = table.cursors
            .filter { $0.value.pendingDelete && $0.value.deletedAtMs == nil
                        && !diff.deferred.contains($0.key) }
            .keys.sorted()
        let tombstoneSlice = ownedTombstoneSlice(registration, table: table,
                                                 candidates: deleteCandidates, budget: &budget)
        // Repair a cursor with reconciled data but no entityId (R-exec-1). Older builds could
        // create this inconsistent state by parking without harvesting server identity; consumed
        // versions would never redeliver, suppressing local tombstones and permitting blind creates
        // on edits. Resubmit using the unchanged client tag so the server's unique-tag upsert
        // returns the real identity/version, as Space repair does.
        // A store-birthday reset intentionally produces the same shape by clearing server
        // identity/version/baseline while retaining reconciled history (F-PK-1). Its full-replay
        // gate prevents repair until the new store has drained; incoming replay harvests existing
        // identities first, leaving only truly absent ones to recreate.
        // Restrict repair to eligible live snapshot rows without parked payloads or pending
        // deletion. Successful repair removes the predicate; three consecutive repair rejections
        // stop rearming (R-exec-13). Rows no longer local cannot supply repair payloads and await
        // peer updates or retention expiry.
        let unkeyed = Set(table.cursors.filter {
            $0.value.entityId.isEmpty && $0.value.reconciled != nil
                && $0.value.deletedAtMs == nil && $0.value.pendingApply == nil
                && !$0.value.pendingDelete
                && ($0.value.rekeyRejectRounds ?? 0) < Self.rekeyRejectGiveUpRounds
                && snapshot.entities[$0.key] != nil
        }.keys)
        if !unkeyed.isEmpty, onlyIdentities == nil {
            // R12: report kind/count, not identities.
            AppLogWarn("[phi-sync] owned-item cursors carry a baseline but no entity id "
                       + "kind=\(registration.label) count=\(unkeyed.count); "
                       + "republishing them to re-key through the client tag")
        }
        // Republishing locally winning fields must be durable (section 6.2). A per-round set can be
        // lost to slice limits, retirement or process exit; after landing, local bytes equal
        // reconciled and ordinary diff no longer exposes the account disagreement. Use nonnil
        // server and reconciled baselines that differ.
        // Nil server means unknown account state, handled by the bounded unkeyed repair path;
        // treating nil as disagreement would bypass its three-rejection limit. Exclude
        // pendingTombstone too (F-CX-4): an update using the harvested tombstone version would
        // resurrect the account entity just before its parked deletion removes the local row.
        let pending = Set(table.cursors.filter {
            $0.value.reconciled != nil && $0.value.server != nil
                && $0.value.server != $0.value.reconciled
                && $0.value.deletedAtMs == nil && $0.value.pendingApply == nil
                && !$0.value.pendingDelete && !$0.value.pendingTombstone
        }.keys)
        // Keep the in-round set as an optimization for newly landed parked merges with no incoming
        // entity to refresh the durable server baseline.
        let republish = (ownedMustRepublish[registration.label] ?? []).union(unkeyed)
            .union(pending)
        // Best-effort deferral applies only to identities minted this round under owners with
        // incoming entities of this kind (sections 5.3/6.4). It narrows join-time duplicate races;
        // stateless adoption remains safe in either order, with duplication as the residual race
        // (section 6.5). Existing identities publish real edits normally. Compare
        // snapshot.ownerUuids, the containing owner, not owners(_:) parent references.
        let deferredOwners = ownedDeferredOwners[registration.label] ?? []
        var liveCandidates: [String] = []
        for (identity, bytes) in snapshot.entities {
            guard table.cursors[identity]?.pendingDelete != true else { continue }
            // Withhold failed rule-3b admission: revocation may already have deleted the row while
            // this snapshot still holds stale bytes; the no-write branch must also skip publication
            // this round.
            guard !yieldWithheld.contains(identity) else { continue }
            // Never publish an identity with a parked remote tombstone (F-CX-4). Keep this
            // publisher-side guard even though adapters also exclude it from snapshots: sending an
            // update with the harvested tombstone version would resurrect it on the server.
            guard table.cursors[identity]?.pendingTombstone != true else { continue }
            if snapshot.minted[identity] != nil,
               let owner = snapshot.ownerUuids[identity], deferredOwners.contains(owner) {
                continue
            }
            if bytes != table.cursors[identity]?.reconciled || republish.contains(identity) {
                liveCandidates.append(identity)
            }
        }

        // Recompute pendingLocalEdit recovery on each unrestricted publication pass (section
        // 8.4.5(b), 8b-4). It must run after liveCandidates but before slicing and the empty-work
        // return: no-work rounds are precisely where recovery matters (CASE M-19). Do not repeat it
        // during scoped conflict retries.
        // The generic layer computes candidate IDs only; the URL-rule closure owns comparison
        // baselines (R-M3-4a-96). Unwrap every required value and fail closed; Optional nil==nil
        // must not clear flags (CASE M-19x(x2)).
        // Compare this round's snapshot bytes directly with reconciled, not urlRuleLocalProjections
        // or candidate-set membership (RR8-8/9-2). The projection retains baseline rank and would
        // hide an unpublished reorder; snapshot assignRanks exposes it, preserving the flag until
        // applied publication. Rows absent from snapshot, including pending-work or unsigned lazy
        // rows, never qualify (CASE M-19x(x1)).
        if onlyIdentities == nil {
            var clearCandidates: Set<String> = []
            for (identity, bytes) in snapshot.entities {
                guard let cursor = table.cursors[identity],
                      let reconciled = cursor.reconciled,
                      let server = cursor.server,
                      server == reconciled,
                      bytes == reconciled
                else { continue }
                clearCandidates.insert(identity)
            }
            await registration.clearPendingLocalEdits(clearCandidates)
        }

        let liveSlice = ownedLiveSlice(registration, snapshot: snapshot,
                                       candidates: liveCandidates, budget: &budget)
        // Do not recount pending publication during a scoped retry of the same round's
        // snapshot/diff, which would double-count the remaining queue.
        if onlyIdentities == nil {
            counters.pendingPublish += (deleteCandidates.count - tombstoneSlice.count)
                + (liveCandidates.count - liveSlice.count)
        }

        // Batch only readable tags (section 5.5). Skip quarantined hashes: the server's client-tag
        // upsert lacks a version check and a blind write could replace unreadable account data.
        let spaceTableNow = loadSpaceTable()
        var work: [(identity: String, entry: PhiCommitEntry, payload: Data?)] = []
        for identity in tombstoneSlice {
            guard onlyIdentities?.contains(identity) ?? true else { continue }
            guard let cursor = table.cursors[identity],
                  !cursor.entityId.isEmpty, cursor.version > 0 else { continue }
            let hash = PhiSyncEntity.clientTagHash(for: registration.clientTag(identity))
            guard spaceTableNow.unreadableTagHashes[hash] == nil else {
                AppLogWarn("[phi-sync] refusing to commit over an unreadable row "
                           + "tag=\(String(hash.prefix(8)))")
                continue
            }
            work.append((identity,
                         PhiCommitEntry(entityId: cursor.entityId, clientTagHash: hash,
                                        name: registration.entityName, ciphertext: nil,
                                        deleted: true, baseVersion: cursor.version), nil))
        }
        for identity in liveSlice {
            guard onlyIdentities?.contains(identity) ?? true else { continue }
            guard let payload = snapshot.entities[identity] else { continue }
            let cursor = table.cursors[identity]
            let hash = PhiSyncEntity.clientTagHash(for: registration.clientTag(identity))
            guard spaceTableNow.unreadableTagHashes[hash] == nil else {
                AppLogWarn("[phi-sync] refusing to commit over an unreadable row "
                           + "tag=\(String(hash.prefix(8)))")
                continue
            }
            let entityId = (cursor?.entityId.isEmpty ?? true) ? nil : cursor?.entityId
            work.append((identity,
                         PhiCommitEntry(entityId: entityId, clientTagHash: hash,
                                        name: registration.entityName, ciphertext: nil,
                                        deleted: false, baseVersion: cursor?.version ?? 0),
                         payload))
        }
        guard !work.isEmpty else {
            ownedCounters[registration.label] = counters
            writeOwnedTable(registration, table)
            return
        }

        var conflicted: Set<String> = []
        var appliedMinted: [String: String] = [:]
        // Collect applied tombstone identities for the first section 5.7 soft-delete exit.
        var appliedTombstones: Set<String> = []
        // Collect applied live identities for section 8.4.5(a) flag clearing (8b-4).
        var appliedLive: Set<String> = []
        var encryptionFailed = false
        var queue = work
        while !queue.isEmpty {
            let slice = Array(queue.prefix(Self.maxCommitEntriesPerBatch))
            queue.removeFirst(slice.count)
            var entries: [PhiCommitEntry] = []
            var sent: [(identity: String, entry: PhiCommitEntry, payload: Data?)] = []
            for item in slice {
                guard let payload = item.payload else {
                    entries.append(item.entry); sent.append(item); continue
                }
                guard let envelope = try? Phi_PhiEntity(serializedBytes: payload),
                      let key = try? await domainKeys.domainKey(),
                      let ciphertext = try? PhiEntityCodec.encrypt(envelope, key: key) else {
                    // Break rather than return on encryption failure, so outcomes from earlier
                    // accepted slices are still persisted. Losing those baselines would republish
                    // with stale state next round.
                    encryptionFailed = true
                    break
                }
                entries.append(PhiCommitEntry(entityId: item.entry.entityId,
                                              clientTagHash: item.entry.clientTagHash,
                                              name: item.entry.name, ciphertext: ciphertext,
                                              deleted: false,
                                              baseVersion: item.entry.baseVersion))
                sent.append(item)
            }
            if encryptionFailed {
                AppLogError("[phi-sync] owned-item commit aborted kind=\(registration.label): "
                            + "the domain key or the seal failed")
                break
            }
            guard !isStopped, canPublishThisRound else { break }
            let outcomes: [PhiCommitOutcome]
            do {
                outcomes = try await client.commit(entries: entries, storeBirthday: storedBirthday)
            } catch PhiSyncProtocolError.notMyBirthday {
                // Birthday reset rewrites every table; this local copy predates that reset.
                resetForNewStoreBirthday()
                ownedCounters[registration.label] = counters
                return
            } catch {
                AppLogError("[phi-sync] owned-item commit failed kind=\(registration.label) "
                            + "(\(PhiSyncLog.describe(error)))")
                break    // Preserve outcomes from earlier slices.
            }
            guard !isStopped else { return }
            for (item, outcome) in zip(sent, outcomes) {
                applyOwnedCommitOutcome(outcome, for: item, registration: registration,
                                        owner: snapshot.ownerUuids[item.identity],
                                        rekeying: unkeyed.contains(item.identity),
                                        table: &table, counters: &counters,
                                        conflicted: &conflicted)
                if case .applied = outcome, item.payload != nil,
                   let localId = snapshot.minted[item.identity] {
                    appliedMinted[item.identity] = localId
                }
                if case .applied = outcome, item.entry.deleted {
                    appliedTombstones.insert(item.identity)
                }
                // Require item.payload != nil for section 8.4.5(a): applied tombstones do not clear
                // pendingLocalEdit.
                if case .applied = outcome, item.payload != nil {
                    appliedLive.insert(item.identity)
                }
            }
        }

        // Persist minted identities only after server acceptance (section 6.4). If local claim
        // write-back fails, keep the cursor and park its payload: removing it would lose the only
        // record of an accepted entity while the local row remains unclaimed, causing a new
        // identity and an undeletable account duplicate next round.
        // PendingApply suppresses repeat publication and enables later stateless adoption. If the
        // row changes or disappears before retry, the deletion diff can correctly remove the
        // account entity. Preserve ownerUuid too, since the diff conservatively skips unresolved
        // ownership.
        if !appliedMinted.isEmpty {
            let persisted = await registration.claimIdentities(appliedMinted)
            for identity in appliedMinted.keys where !persisted.contains(identity) {
                guard var cursor = table.cursors[identity] else { continue }
                cursor.pendingApply = cursor.reconciled
                if cursor.ownerUuid == nil { cursor.ownerUuid = snapshot.ownerUuids[identity] }
                table.cursors[identity] = cursor
            }
        }

        // Clear section 8.4.5(a) flags after claimIdentities and before writeOwnedTable (8b-4 /
        // ruling 5). New rules can only be addressed by syncId after write-back; failed claims
        // remain safe no-ops. Rule-3b republishing after a yield must use the same comparison
        // guard, never unconditional clearing, because it represents an unpublished local edit
        // finally accepted (ruling 13 / CASE M-7d).
        if !appliedLive.isEmpty {
            await registration.notePublishApplied(appliedLive)
        }

        ownedCounters[registration.label] = counters
        let saved = writeOwnedTable(registration, table)

        // Hard-delete local soft-deleted rows only after the applied tombstone cursor is
        // successfully persisted (section 5.7). A crash after that leaves an orphaned soft-deleted
        // row for retention cleanup. Reversing the order leaves a baseline without deletedAtMs or a
        // local row, causing another tombstone next round. Failed saves leave the invisible row
        // intact for retry or the second exit; its mergePartnerSyncId disappears with the row.
        if saved, !appliedTombstones.isEmpty,
           let hardDelete = registration.hardDeleteAfterTombstone {
            await hardDelete(appliedTombstones)
        }

        // One pull and one retry restricted to conflicted identities; a second conflict abandons
        // only those entries for this round (section 5.3).
        if retryOnConflict, !conflicted.isEmpty {
            guard await pull(retryOnBirthday: true, thenPush: false) else { return }
            await publishOwnedKind(registration, maps: maps, retryOnConflict: false,
                                   onlyIdentities: conflicted)
        }
    }

    /// Publication outcome write-back, matching applySpaceCommitOutcome. The caller supplies
    /// rekeying from the set actually armed this round; do not recompute from a cursor that earlier
    /// outcomes in this batch may already have changed.
    private func applyOwnedCommitOutcome(
        _ outcome: PhiCommitOutcome,
        for item: (identity: String, entry: PhiCommitEntry, payload: Data?),
        registration: OwnedKindRegistration,
        owner: String?,
        rekeying: Bool,
        table: inout PhiOwnedItemTable,
        counters: inout OwnedRoundCounters,
        conflicted: inout Set<String>
    ) {
        let existing = table.cursors[item.identity]
        var cursor = existing ?? PhiOwnedItemCursor()
        let isTombstone = item.entry.deleted
        switch outcome {
        case .applied(let entityId, let version, let storeBirthday):
            if !entityId.isEmpty { cursor.entityId = entityId }
            cursor.version = version
            storedBirthday = storeBirthday
            if isTombstone {
                // Every cursor leaving the live state receives deletedAtMs, which drives the 30-day
                // expiry scan (R-M3-3-7 / section 3.6).
                cursor.pendingDelete = false
                cursor.deleteRejectRounds = 0
                cursor.reconciled = nil
                cursor.server = nil
                cursor.deletedAtMs = now()
                counters.tombstones += 1
            } else if let payload = item.payload {
                // Update both reconciled and server after acceptance: the server now holds exactly
                // the submitted bytes. Updating only reconciled leaves server stale and defeats
                // redundant-publication suppression (R-exec-7).
                cursor.reconciled = payload
                cursor.server = payload
                // Newly created cursors also need ownerUuid (A12). The pre-commit owner refresh
                // only touched existing cursors; omitting ownership here would permanently prevent
                // deletion diff from removing an accepted minted identity whose local row was never
                // claimed.
                if let owner { cursor.ownerUuid = owner }
                if cursor.deletedAtMs != nil {
                    cursor.deletedAtMs = nil        // Resurrection under §4.2 rule 3b.
                    counters.resurrected += 1
                }
                cursor.deleteRejectRounds = 0
                // Successful publication restored a real ID, so reset consecutive rekey failures,
                // matching deletion retry accounting (R-exec-13).
                cursor.rekeyRejectRounds = nil
                counters.pushed += 1
            }
        case .conflict(let serverVersion):
            // Conflicts do not acknowledge baselines; doing so would silently lose local edits.
            // However, accept a newer returned server_version for an existing cursor (R-exec-17).
            // The intervening pull may return no update, so ignoring this version makes the scoped
            // retry repeat the same stale base_version and amplify commit storms. Never create an
            // empty cursor for an unaccepted identity, and never move version backwards.
            if let serverVersion, existing != nil, serverVersion > cursor.version {
                cursor.version = serverVersion
                table.cursors[item.identity] = cursor
            }
            conflicted.insert(item.identity)
            return
        case .invalidMessage:
            // A rejection must not create a cursor where none existed.
            guard existing != nil else { return }
            guard isTombstone else {
                // The server lacks this row: clear its server triple and recreate by client tag
                // next round. Retain reconciled as local timestamp history, not a statement about
                // the server. The unkeyed repair path explicitly republishes this state without
                // requiring a changed snapshot.
                cursor.entityId = ""
                cursor.version = 0
                cursor.server = nil
                // Count only attempts armed as rekey repair (R-exec-13 / F-PK-2), not unrelated
                // transient rejections of normal edits. Stop rearming after three failures to avoid
                // endless periodic retries. Keep the local row, baseline and ownership; only the
                // repair path is disabled.
                guard rekeying else { break }
                let rejected = (cursor.rekeyRejectRounds ?? 0) + 1
                cursor.rekeyRejectRounds = rejected
                if rejected == Self.rekeyRejectGiveUpRounds {
                    // Log once when the threshold is crossed; the identity will no longer enter
                    // repair slices afterwards. R12 permits kind, tag prefix and count only.
                    AppLogWarn("[phi-sync] giving up on re-keying an owned-item cursor after "
                               + "\(rejected) rejections kind=\(registration.label) "
                               + "tag=\(String(item.entry.clientTagHash.prefix(8)))")
                }
                break
            }
            // A rejected tombstone does not prove absence: server data-type parsing outside the
            // transaction can fail transiently with the same code. Retry unchanged, then finalize
            // locally after three rejected rounds.
            cursor.deleteRejectRounds += 1
            if cursor.deleteRejectRounds >= Self.tombstoneRejectGiveUpRounds {
                AppLogError("[phi-sync] giving up on an owned-item tombstone after "
                            + "\(cursor.deleteRejectRounds) rejections "
                            + "tag=\(String(item.entry.clientTagHash.prefix(8)))")
                cursor.pendingDelete = false
                cursor.reconciled = nil
                cursor.server = nil
                cursor.deletedAtMs = now()
            }
        case .rejected(let type):
            // Like conflict, this outcome provides no cursor-state evidence. Writing defaults would
            // create a ghost cursor.
            AppLogError("[phi-sync] owned-item commit rejected response_type=\(type) "
                        + "tag=\(String(item.entry.clientTagHash.prefix(8)))")
            return
        }
        table.cursors[item.identity] = cursor
    }

    /// Doctor only the table copy passed to snapshot for local split removal (section 7.4). Use the
    /// same round timestamp and mappings as snapshot, distinguishing genuine local unlink from
    /// intact pairs. Batch candidates with baselines and no pendingPartnerLineage into one
    /// MainActor call per kind, avoiding one hop per cursor; kinds without split semantics skip the
    /// whole operation.
    private func doctoredOwnedTable(_ registration: OwnedKindRegistration,
                                    _ table: PhiOwnedItemTable,
                                    maps: OwnedOwnerMaps,
                                    now: Int64) async -> PhiOwnedItemTable {
        guard let clear = registration.clearedSplitPartners else { return table }
        var candidates: [String: Data] = [:]
        for (identity, cursor) in table.cursors {
            guard cursor.pendingPartnerLineage == nil, let bytes = cursor.reconciled else {
                continue
            }
            candidates[identity] = bytes
        }
        guard !candidates.isEmpty else { return table }
        var doctored = table
        for (identity, cleared) in await clear(candidates, now, maps) {
            doctored.cursors[identity]?.reconciled = cleared
        }
        return doctored
    }

    /// Live slice: topological order with prefix closure (F2). Include a child only if its
    /// candidate parent is already in the slice or outside the candidate set, and order parents
    /// first so every delivered boundary forms a prefix-closed tree.
    private func ownedLiveSlice(_ registration: OwnedKindRegistration,
                                snapshot: OwnedSnapshotBytes,
                                candidates: [String],
                                budget: inout Int) -> [String] {
        let candidateSet = Set(candidates)
        var parentOf: [String: String] = [:]
        for identity in candidates {
            guard let bytes = snapshot.entities[identity] else { continue }
            if let parent = registration.owners(bytes).first(where: { candidateSet.contains($0) }) {
                parentOf[identity] = parent
            }
        }
        let depths = Self.ownedDepths(of: candidates, parentOf: parentOf)
        let ordered = candidates.sorted {
            let left = depths[$0] ?? 0, right = depths[$1] ?? 0
            return left == right ? $0 < $1 : left < right
        }
        var out: [String] = []
        var admitted: Set<String> = []
        for identity in ordered {
            guard out.count < budget else { break }
            if let parent = parentOf[identity], !admitted.contains(parent) { continue }
            out.append(identity)
            admitted.insert(identity)
        }
        budget -= out.count
        return out
    }

    /// Tombstone slice: children first, whole-subtree grouping, and dependencies satisfied only by
    /// applied outcomes (R-M3-3-24). Merely placing descendants earlier is insufficient because
    /// repeated conflicts can abandon them while later parent batches still run. deletedAtMs is not
    /// proof of server acceptance.
    /// Intentional B8 exception: after a descendant exhausts three rejection retries, allow its
    /// ancestor and emit a warning rather than block forever.
    private func ownedTombstoneSlice(_ registration: OwnedKindRegistration,
                                     table: PhiOwnedItemTable,
                                     candidates: [String],
                                     budget: inout Int) -> [String] {
        guard !candidates.isEmpty else { return [] }
        let candidateSet = Set(candidates)
        // Decode parent relationships from baselines; tombstones have no payload.
        var parentOf: [String: String] = [:]
        for identity in candidates {
            guard let bytes = table.cursors[identity]?.reconciled else { continue }
            if let parent = registration.owners(bytes).first(where: {
                candidateSet.contains($0) || table.cursors[$0] != nil
            }) {
                parentOf[identity] = parent
            }
        }
        var childrenOf: [String: [String]] = [:]
        for (child, parent) in parentOf { childrenOf[parent, default: []].append(child) }

        // Withhold ancestors while descendant tombstones remain unaccepted.
        var blocked: Set<String> = []
        var gaveUp = 0
        for identity in candidates {
            var stack = childrenOf[identity] ?? []
            while let child = stack.popLast() {
                stack.append(contentsOf: childrenOf[child] ?? [])
                // childrenOf contains only current candidates, already filtered to deletedAtMs nil.
                // Previously accepted descendants are absent from this graph and cannot block
                // ancestors.
                guard let cursor = table.cursors[child] else { continue }
                if cursor.deleteRejectRounds >= Self.tombstoneRejectGiveUpRounds {
                    gaveUp += 1
                    continue
                }
                blocked.insert(identity)
            }
        }
        if gaveUp > 0 {
            AppLogWarn("[phi-sync] an owned-item ancestor tombstone is going out over "
                       + "\(gaveUp) descendant tombstone(s) the account kept rejecting "
                       + "kind=\(registration.label)")
        }

        // Group by the highest deleted ancestor and take each subtree entirely or not at all (V16).
        // Splitting it would expose a partially removed subtree under a still-live folder between
        // rounds.
        var rootOf: [String: String] = [:]
        for identity in candidates {
            var cursor = identity
            var hops = 0
            while let parent = parentOf[cursor], hops <= candidates.count {
                cursor = parent
                hops += 1
            }
            rootOf[identity] = cursor
        }
        let depths = Self.ownedDepths(of: candidates, parentOf: parentOf)
        var groups: [String: [String]] = [:]
        for identity in candidates { groups[rootOf[identity] ?? identity, default: []].append(identity) }

        var out: [String] = []
        for root in groups.keys.sorted() {
            let members = (groups[root] ?? []).filter { !blocked.contains($0) }.sorted {
                let left = depths[$0] ?? 0, right = depths[$1] ?? 0
                return left == right ? $0 < $1 : left > right        // Children before parents.
            }
            guard !members.isEmpty else { continue }
            // Allow a single subtree larger than the whole-round budget. Otherwise that deletion
            // could never progress; the cap limits queue occupancy rather than permanently
            // suppressing work.
            guard out.isEmpty || out.count + members.count <= budget else { continue }
            out.append(contentsOf: members)
        }
        budget = max(0, budget - out.count)
        return out
    }

    /// Walk parentOf to the root, bounded by parentOf.count hops. Cycles therefore produce finite
    /// depths instead of hanging sorting.
    private static func ownedDepths(of identities: [String],
                                    parentOf: [String: String]) -> [String: Int] {
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

    /// One section 11.2 log line per registered kind, named by label. Field declaration order
    /// determines output order.
    private func logOwnedRounds() {
        guard spaceSectionEnabled, spaceStore != nil else { return }
        for registration in ownedKinds {
            var counters = ownedCounters[registration.label] ?? OwnedRoundCounters()
            let table = ownedTables[registration.label] ?? PhiOwnedItemTable()
            // parked is final table state, not a round increment (section 11.2). Count it here and
            // store the same value for test access and logging.
            let parked = table.cursors.values
                .filter { $0.pendingApply != nil || $0.pendingTombstone }.count
            counters.parked = parked
            ownedCounters[registration.label] = counters
            AppLogInfo(Self.ownedRoundLogLine(registration, counters: counters))
        }
    }

    /// Pure formatter for section 11.2/13.2 counters. Extracted so CASE U-27 can verify field-level
    /// text while preserving bookmark/pin lines byte-for-byte. The caller sets counters.parked from
    /// the table first. R12 permits kind/counts only, never user content.
    static func ownedRoundLogLine(_ registration: OwnedKindRegistration,
                                  counters: OwnedRoundCounters) -> String {
        let unreadable = counters.unreadable
        var line = "[phi-sync] \(registration.label) pulled=\(counters.pulled) "
            + "applied=\(counters.applied) parked=\(counters.parked) pushed=\(counters.pushed) "
            + "tombstones=\(counters.tombstones) "
        if registration.reportsAdoption {
            line += "adopted=\(counters.adopted) "
                + "unmatched_folders=\(counters.unmatchedFolders) "
                + "unmergeable_pairs=\(counters.unmergeablePairs) "
        }
        if registration.reportsScope { line += "relineaged=\(counters.relineaged) " }
        line += "resurrected=\(counters.resurrected) "
            + "pending_publish=\(counters.pendingPublish) refused=\(counters.refused) "
            + "superseded_by_delete=\(counters.supersededByDelete) "
            + "rehomed_cursors=\(counters.rehomedCursors) unreadable=\(unreadable) "
            + "excluded_unmapped_owner=\(counters.excludedUnmappedOwner) "
            + "local_read_failed=\(counters.localReadFailed)"
        // Append rule counters at the tail (section 13.2 / R-M3-4a-55). Rule and scope reporting
        // are mutually exclusive.
        if registration.reportsRuleCounters {
            line += " normalized=\(counters.normalized)"
                + " owner_moved=\(counters.ownerMoved) adopted=\(counters.adopted)"
                + " collapsed=\(counters.collapsed) transferred=\(counters.transferred)"
                + " yield_no_partner=\(counters.yieldNoPartner)"
        }
        if registration.reportsScope { line += " scope_mismatch=\(counters.scopeMismatch)" }
        return line
    }

    // MARK: - Guarded writes
    //
    // Everything this engine writes into the shared `UserDefaults` goes through one of the
    // three functions here or in the section below, each of which reads the retirement flag
    // immediately before its write. The guards at the rounds' entry and suspension points are
    // an optimisation on top of that (they stop useless work and useless network), not the
    // mechanism: `shutdown()` runs concurrently with the round, so a check taken at the top of
    // `apply` or `push` says nothing about the flag's value a few statements later. See
    // `shutdown()` for the exact guarantee this buys and the residue it leaves.

    /// Single write path for the settings themselves. Returns whether the write happened, so a
    /// caller can skip the cursor bookkeeping that only makes sense once the values landed.
    @discardableResult
    private func writeSettings(_ entity: Phi_PhiSettingEntity) -> Bool {
        guard !isStopped else { return false }
        isApplyingRemote = true
        SyncableSettings.apply(entity, to: defaults, settings: settings)
        isApplyingRemote = false
        return true
    }

    private func loadSpaceTable() -> PhiSpaceSyncTable {
        spaceStore?.load() ?? PhiSpaceSyncTable()
    }

    /// Single sync.phiSpaces write path, guarded against retirement so an old round cannot
    /// overwrite freshly cleared account state (section 3.3 step 2.0). Return confirmed
    /// persistence; retirement and absent store are successful no-ops, since settings-only engines
    /// normally have no Space store (R-M3-4a-83/16). Refresh main-thread caches only after save
    /// succeeds, avoiding sidebar state that differs from disk and reappears on restart.
    @discardableResult
    private func writeSpaceTable(_ table: PhiSpaceSyncTable) -> Bool {
        // Both early returns are successful no-ops (R-M3-4a-16).
        guard !isStopped, let spaceStore else { return true }
        // This write boundary also counts every derived-state failure, including gate-closed marker
        // tracking, drain flags and guard-2 latches, because they all use mutateSpaceTable (section
        // 2.5(4) / ruling 4).
        guard spaceStore.save(table) else {
            cursorSaveFailures += 1
            return false
        }
        Task { @MainActor in PhiSpaceSyncState.shared.refreshCaches(from: table) }
        return true
    }

    /// Apply fresh deltas to sync.phiSpaces. Marker-derived state must persist per page and before
    /// that page's marker (R-M3-4a-77); a round-end write would lose page-1 observations if page 2
    /// fails. The closure reads current state, avoiding stale copies across suspension; gate edges
    /// are serialized rounds too.
    /// Skip unchanged mutations without a plist write or cache refresh. AccountUserDefaults
    /// rollback ensures memory still equals disk after failed writes, so a later retry sees the
    /// delta and saves again (R-M3-4a-83 / section 2.5(3)). Return confirmed persistence for
    /// replay-arming, gate bookkeeping and drain finalization. An unchanged durable value is
    /// success, not cursorSaveFailure.
    @discardableResult
    private func mutateSpaceTable(_ body: (inout PhiSpaceSyncTable) -> Void) -> Bool {
        var table = loadSpaceTable()
        let before = table
        body(&table)
        guard table != before else { return true }
        return writeSpaceTable(table)
    }

    /// `mutateSpaceTable`'s sibling for the §5.3 intents delivered by
    /// `PhiSpaceSyncState`: the same read-modify-write against `sync.phiSpaces`,
    /// except that the intent itself reports whether it changed anything, so the
    /// caller can decide to queue a push instead of the engine guessing from a
    /// `!=` comparison.
    ///
    /// `body` may not suspend, so the read-modify-write itself cannot be torn.
    /// That is NOT what makes the intent safe, though: exclusion against the
    /// rounds that hold a table copy across their own suspensions comes from the
    /// queue, and every caller of this helper is already a `Round` body
    /// (`.recordLocalDeletion`). Never call it from a public entry point.
    @discardableResult
    private func runSpaceIntent(_ body: (inout PhiSpaceSyncTable) -> Bool) -> Bool {
        // Redundant with `writeSpaceTable`'s own `guard let spaceStore`, but it
        // avoids a pointless `PhiSpaceSyncTable()` round trip on a settings-only
        // engine.
        guard spaceStore != nil else { return false }
        var table = loadSpaceTable()
        let changed = body(&table)
        if changed { writeSpaceTable(table) }
        return changed
    }

    // MARK: - Hybrid logical clock (C2 / R2.1)

    /// A fresh LWW stamp: `max(wall, maxSeen + 1)`. Used for the `now:` argument of every
    /// snapshot/stamp call, for `clearedPinSplitPartner`, and for `deleteDecidedAtMs` — see
    /// `SyncableOwnedItems.tombstones`, where A9 compares that field against a wire stamp.
    private func hlcNow() -> Int64 {
        let stamp = hlcClock.stamp(wallMs: now())
        persistHlcMax()
        return stamp
    }

    /// Fold landed LWW stamps into logical time. Called at landing, before anything in the same
    /// round stamps, so `hlcNow()` already exceeds every value this round could overwrite.
    ///
    /// ONLY `PhiSettingValue.updated_at_ms` values reach here. `created_at_ms` is deliberately
    /// excluded: it is a creation instant merged with `min()`, not an LWW stamp, and a peer
    /// claiming to have been created in 2099 must not drag the whole account's logical time
    /// with it. So are `deletedAtMs`, `purgedAtMs` and `refusedAtMs`, which are wall-clock
    /// quantities compared against `now()`.
    ///
    /// Missing a field here is not a correctness hole: AM-1 stamps a changed field at least one
    /// above the baseline stamp it overwrites, which covers the per-field case on its own.
    private func observeStamps(_ values: [Phi_PhiSettingValue]) {
        let before = hlcClock.maxSeen
        for value in values { hlcClock.observe(value.updatedAtMs) }
        guard hlcClock.maxSeen != before else { return }
        persistHlcMax()
    }

    private func observeStamps(of entity: Phi_PhiSettingEntity) {
        observeStamps(Array(entity.values.values))
    }

    private func observeStamps(of entity: Phi_PhiSpaceEntity) {
        observeStamps([entity.name, entity.iconName, entity.colorHex, entity.rank,
                       entity.profileUuid, entity.themeID,
                       entity.overlayOpacityLight, entity.overlayOpacityDark])
    }

    /// Owned kinds are landed generically, so the three payload shapes are unwrapped here
    /// rather than through a fourth `OwnedItemKind` member.
    private func observeStamps(of envelope: Phi_PhiEntity) {
        switch envelope.kind {
        case .bookmark(let entity):
            observeStamps([entity.spaceUuid, entity.parentUuid, entity.rank, entity.title,
                           entity.url, entity.secondaryURL, entity.secondaryTitle])
        case .pinTab(let entity):
            observeStamps([entity.rank, entity.title, entity.url, entity.splitPartnerUuid])
        case .urlRule(let entity):
            observeStamps([entity.host, entity.pathPrefix, entity.ask, entity.targetSpaceUuid,
                           entity.rank])
        case .space(let entity):
            observeStamps(of: entity)
        case .setting(let entity):
            observeStamps(of: entity)
        case .none:
            break
        }
    }

    private func persistHlcMax() {
        writeState(NSNumber(value: hlcClock.maxSeen), forKey: Self.hlcMaxStateKey)
    }

    /// `SyncableSettings.snapshot` is a write as much as a read: for every registered key whose
    /// value differs from `<key>.phiSyncVal` it stamps `<key>.phiSyncTs` and refreshes the
    /// sidecar. So it takes the same check as the settings and the cursor. `nil` means the
    /// engine was retired and nothing was stamped.
    ///
    /// The sidecars survive an account switch (they sit next to the preference keys and are not
    /// account-scoped) while `hlcMax` does not, so the result's stamps are folded back in:
    /// after a wipe this device must not issue a stamp below one it has already published.
    private func snapshotLocalSettings() -> Phi_PhiSettingEntity? {
        guard !isStopped else { return nil }
        let entity = SyncableSettings.snapshot(defaults, now: hlcNow(), settings: settings)
        observeStamps(of: entity)
        return entity
    }

    // MARK: - Persisted state accessors

    /// Single write path for the account-scoped cursor keys, so the shutdown check cannot be
    /// forgotten at one of the five `UserDefaults` accessors below. `nil` removes the key.
    /// The marker and the birthday do not come through here: they go to `marker.json` via
    /// `persistMarkerState`, which carries the same shutdown check.
    private func writeState(_ value: Any?, forKey key: String) {
        guard !isStopped else { return }
        guard let value else { return defaults.removeObject(forKey: key) }
        defaults.set(value, forKey: key)
    }

    /// True once this device has settings history for the account: a pull applied the account's
    /// entity, or this device committed a snapshot of its own. Either way `<key>.phiSyncTs`
    /// sidecars now exist for the registered keys, which is what makes a field-level merge
    /// meaningful — so this, not the presence of a server cursor, gates the wholesale adopt in
    /// `apply`. The two used to be the same predicate, and the coupling was a silent data
    /// loss: `clearEntityCursor()` (the tombstone heal, the full-replay branch) forgets which
    /// row the settings live in, and the next readable entity was then adopted wholesale over
    /// local edits whose debounced push had not run yet.
    ///
    /// Not derived from the sidecars themselves: those sit next to the preference keys and are
    /// not account-scoped, so they outlive the cursor wipe and would stop a device from
    /// adopting the settings of an account it has just switched to. This is cleared only by an
    /// account-scope reset of `stateKeys` — in the app that is
    /// `PhiChromiumCoordinator.resetPhiSyncCursorIfAccountChanged`, run before the new
    /// account's engine is built; `resetSyncState()` does the same wipe from in here.
    ///
    /// One known window, accepted rather than closed. When a device's only sight of the entity
    /// was `.unusable`, the pull records `storedEntityId` before dropping the baseline while
    /// `hasAdopted` remains false, and `push` returns at its "an entity id with no
    /// baseline" guard *before* `SyncableSettings.snapshot` can stamp anything. A setting the
    /// user changes in that window is therefore adopted over — not merged — once the entity
    /// becomes readable, with no log line of its own.
    ///
    /// Merging there instead would cost more. `snapshot` treats a key with no `<key>.phiSyncVal`
    /// as locally changed, so on a device with no sidecar history at all it stamps *every*
    /// registered key `now`: the merge would hand this device's whole local default set the
    /// newest timestamps in the account and the trailing push would publish it over every other
    /// device. Stamping the sidecars inside the guard to "give the merge real timestamps" has
    /// the same defect — the fabricated timestamps would be `now` for every key, not just the
    /// one the user touched, because nothing here knows which key changed. So the guard leaves
    /// no trace on purpose, and the smaller loss stands.
    /// `testAnUnreadableEntityLaterAdoptsWholesaleOverAnEditMadeInThatWindow` pins the choice.
    private var hasAdopted: Bool {
        get { defaults.bool(forKey: Self.hasAdoptedStateKey) }
        set {
            let stored: Bool? = newValue ? true : nil
            writeState(stored, forKey: Self.hasAdoptedStateKey)
        }
    }

    /// Forgets which entity the account's settings live in, keeping the progress marker, the
    /// store birthday and `hasAdopted` — this says the row is gone, never that this device has
    /// no settings history. Used when the server proves that entity is gone; the next round
    /// takes the create path, which the server resolves by `client_tag_hash`.
    private func clearEntityCursor() {
        storedEntityId = nil
        storedVersion = nil
        storedLastEntity = nil
    }

    /// `clearEntityCursor()` plus the progress marker, so the next pull replays the whole type
    /// instead of asking for changes after a watermark that describes a row the server no
    /// longer has. Same-account recovery — the store birthday and `hasAdopted` stay.
    private func clearRemoteCursor() {
        clearEntityCursor()
        storedMarker = nil
        // A full replay re-reads the settings entity anyway (review A3).
        unreadableSettingsRecord = nil
    }

    /// The store this device was tracking is gone (NOT_MY_BIRTHDAY): every cursor that
    /// describes it is void, birthday included, and any tombstone streak counted against the
    /// old store means nothing.
    ///
    /// `hasAdopted` survives, because the *account* did not change — only the server's store
    /// identity did. The `<key>.phiSyncTs` sidecars this device has been keeping still describe
    /// this account's settings, so the next readable entity must be merged against them, not
    /// adopted over them. (Only an account-scope reset of `stateKeys` clears it — see
    /// `hasAdopted`.) The Space table's *server-side* triples are cleared alongside for the
    /// same reason and with the same exception: what describes the store goes, what describes
    /// this account's own history stays.
    private func resetForNewStoreBirthday() {
        canPublishThisRound = false
        clearRemoteCursor()
        storedBirthday = ""
        tombstoneRounds = 0
        guard spaceStore != nil else { return }
        // The server holds a different data set now, so every server-side triple and every
        // loss guard has to be re-armed. `reconciled` / `hidden` / `deletedAtMs` / `purgedAtMs`
        // survive: the ACCOUNT did not change, and clearing them would re-arm the wholesale
        // adopt and silently drop edits this device has just stamped.
        mutateSpaceTable { table in
            for (uuid, var cursor) in table.cursors {
                cursor.entityId = nil
                cursor.version = 0
                cursor.server = nil
                cursor.deleteRejectRounds = 0
                table.cursors[uuid] = cursor
            }
            table.hasDrainedFullReplay = false
            table.drainInProgress = false
            table.markerMovedWhileGateShut = false
            table.didReplayForEmptyTable = false
            table.lastDrainedBirthday = nil
            table.unreadableTagHashes = [:]
            table.bookmarksReplayedForEmptyTable = false
            table.pinsReplayedForEmptyTable = false
            // Reset the URL-rule replay latch after changing stores, allowing future file-loss
            // replay (section 10). Keep urlRulesHadRecords and reconciled: changing stores does not
            // erase this device's publication history.
            table.urlRulesReplayedForEmptyTable = false
        }
        // For owned cursors, clear only server identity/version/state while retaining local
        // reconciled history. Clearing tables/files would destroy baselines and enable blind
        // account overwrites (section 3.5).
        for registration in ownedKinds {
            var table = ownedTables[registration.label] ?? registration.store
                .load(hadRecords: loadSpaceTable()[keyPath: registration.flags.hadRecords]).table
            for (identity, var cursor) in table.cursors {
                cursor.entityId = ""
                cursor.version = 0
                cursor.server = nil
                cursor.deleteRejectRounds = 0
                // Reset rekey failures on store change (R-exec-13): old rejections say nothing
                // about the new store. Reset just cleared all entity IDs, so repair must remain
                // available to recover them.
                cursor.rekeyRejectRounds = nil
                table.cursors[identity] = cursor
            }
            writeOwnedTable(registration, table)
        }
    }

    private var storedEntityId: String? {
        get { defaults.string(forKey: Self.entityIdStateKey) }
        set { writeState(newValue, forKey: Self.entityIdStateKey) }
    }

    private var storedVersion: Int64? {
        get { (defaults.object(forKey: Self.versionStateKey) as? NSNumber)?.int64Value }
        set { writeState(newValue.map { NSNumber(value: $0) }, forKey: Self.versionStateKey) }
    }

    /// The sole marker/birthday write-through path (M3-4a section 2.10): update the mirror, save,
    /// and roll back on failure. Preserve the retirement guard inherited from writeState; retired
    /// engines still reference the previous account store and must not recreate a file deleted
    /// during self-revocation.
    /// Without rollback, replaying the same page could appear unchanged in memory and skip
    /// persistence while disk remains stale. Count failed marker or birthday saves here for B-2's
    /// page-end gate (R-M3-4a-83 / ruling 4). Call persistStoredMarker when the caller needs the
    /// Bool result.
    @discardableResult
    private func persistMarkerState(_ updated: PhiSyncMarkerFile) -> Bool {
        guard !isStopped else { return true }              // §2.5 rule 4: early return is not a failure.
        guard updated != markerState else { return true }  // No change means no save; likewise not a failure.
        let previous = markerState
        markerState = updated
        guard markerStore.save(updated) else {
            markerState = previous
            cursorSaveFailures += 1
            return false
        }
        return true
    }

    /// Result-returning storedMarker setter for page-end persistence and step 1 of both
    /// replay-recovery paths. Normalize empty markers to nil exactly as the setter does.
    @discardableResult
    private func persistStoredMarker(_ newValue: Data?) -> Bool {
        var updated = markerState
        updated.marker = Self.normalizedMarker(newValue)
        return persistMarkerState(updated)
    }

    /// An empty marker is stored as `nil`: on the wire "no marker" and "empty marker" are the
    /// same request, and `nil` is the value every full-replay predicate here compares against.
    private static func normalizedMarker(_ marker: Data?) -> Data? {
        (marker?.isEmpty ?? true) ? nil : marker
    }

    /// The empty string is "not known yet" on the wire. It lives in `marker.json` beside the
    /// marker (M3-4a): the birthday is written page by page (§2.4), and the two must roll back
    /// together on a user-data import — a birthday kept anywhere else would come back stale
    /// and loop on NOT_MY_BIRTHDAY.
    private var storedBirthday: String {
        get { markerState.storeBirthday }
        set {
            var updated = markerState
            updated.storeBirthday = newValue
            persistMarkerState(updated)
        }
    }

    /// See `normalizedMarker`: an empty marker is stored as `nil`. The setter discards the
    /// write's Bool; call sites that need it go through `persistStoredMarker(_:)`.
    private var storedMarker: Data? {
        get { markerState.marker }
        set { persistStoredMarker(newValue) }
    }

    /// Consecutive pulls that found the account's settings row tombstoned. Zero is stored as
    /// "absent" so `stateKeys` stays a clean "nothing persisted" set after a cursor wipe.
    private var tombstoneRounds: Int {
        get { defaults.integer(forKey: Self.tombstoneRoundsStateKey) }
        set {
            let stored: Int? = newValue > 0 ? newValue : nil
            writeState(stored, forKey: Self.tombstoneRoundsStateKey)
        }
    }

    private var storedLastEntity: Phi_PhiSettingEntity? {
        get {
            guard let bytes = defaults.data(forKey: Self.lastEntityStateKey) else { return nil }
            return try? Phi_PhiSettingEntity(serializedBytes: bytes)
        }
        set { writeState(newValue.flatMap { try? $0.serializedData() }, forKey: Self.lastEntityStateKey) }
    }

    /// See `UnreadableSettingsRecord` (review A3). Account-scoped like the other cursor keys.
    private var unreadableSettingsRecord: UnreadableSettingsRecord? {
        get {
            guard let bytes = defaults.data(forKey: Self.unreadableSettingsStateKey) else { return nil }
            return try? JSONDecoder().decode(UnreadableSettingsRecord.self, from: bytes)
        }
        set { writeState(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: Self.unreadableSettingsStateKey) }
    }
}

// MARK: - Bookmark registration
// Concrete bookmark behavior is isolated in this registration; the engine above drives generic
// kinds through the registry. Pin registration follows the same pattern.

/// Main-actor bookmark state for a round. Reuse the single initial fetch across snapshot, diff,
/// index projection and landing, matching AccountPhiBookmarkAccess's cache (section 5.7(2)).
@MainActor
final class BookmarkSyncRoundState {
    private(set) var locals: [PhiLocalBookmark] = []
    private(set) var identityToGuid: [String: String] = [:]
    private(set) var rowByGuid: [String: PhiLocalBookmark] = [:]
    /// Section 6 claim pairs: entity identity to local GUID. Accumulate parked retries and incoming
    /// planning so snapshot mint suppression and pendingClaims exemptions see their union.
    private(set) var pairs: [String: String] = [:]

    func mergePairs(_ pairs: [String: String]) {
        for (identity, guid) in pairs { self.pairs[identity] = guid }
    }

    /// Reflect identities successfully written mid-round in the cached local projection without
    /// another fetch. Otherwise later planning could assign a second identity to the same
    /// apparently unclaimed row and cause rowAlreadyMapped to refuse the whole Space batch
    /// permanently.
    func notePersistedClaims(_ pairs: [String: String]) {
        for (identity, guid) in pairs {
            guard let index = locals.firstIndex(where: { $0.guid == guid }) else { continue }
            locals[index].syncId = identity
            rowByGuid[guid]?.syncId = identity
            identityToGuid[identity] = guid
        }
    }

    /// Remove actually deleted rows from the in-memory round projection, without rereading storage.
    /// Otherwise publication would still see a live row plus deletedAtMs and use rule 3b to
    /// resurrect the remote deletion in the same round (CASE 6b.8).
    func noteDeletedRows(_ guids: Set<String>) {
        guard !guids.isEmpty else { return }
        for guid in guids {
            if let syncId = rowByGuid[guid]?.syncId { identityToGuid.removeValue(forKey: syncId) }
            rowByGuid.removeValue(forKey: guid)
        }
        locals.removeAll { guids.contains($0.guid) }
    }

    func reload(_ rows: [PhiLocalBookmark]) {
        locals = rows
        identityToGuid = [:]
        rowByGuid = [:]
        for row in rows {
            rowByGuid[row.guid] = row
            if let syncId = row.syncId { identityToGuid[syncId] = row.guid }
        }
        pairs = [:]
    }

    /// Replace the round projection with access's post-landing cache, not another fetch (Step 3).
    /// Refresh content and location together, including parentGuid, spaceId and index, or the old
    /// location would be restamped and undo the incoming move. Keep pairs during this round to
    /// prevent reminting just-claimed rows; only reload at a new round clears them.
    func refreshLandedRows(_ rows: [PhiLocalBookmark]) {
        locals = rows
        identityToGuid = [:]
        rowByGuid = [:]
        for row in rows {
            rowByGuid[row.guid] = row
            if let syncId = row.syncId { identityToGuid[syncId] = row.guid }
        }
    }
}

/// Sibling-group key. A nil parentGuid means a direct child of this Space's canonical root.
private struct BookmarkSiblingGroup: Hashable {
    var spaceId: String
    var parentGuid: String?
}

private extension PhiLocalBookmark {
    /// Deletion diff reads only local identity, so represent its allSyncIds() domain with
    /// identity-only shells, not snapshot rows (section 4.7 / R-exec-4).
    static func identityOnly(_ syncId: String) -> PhiLocalBookmark {
        PhiLocalBookmark(syncId: syncId, guid: syncId, spaceId: "", profileId: "",
                         parentGuid: nil, index: 0, isFolder: false, title: "",
                         url: URL(string: "https://bookmark.phi/folder")!,
                         secondaryUrl: nil, secondaryTitle: nil, source: 0,
                         createdDate: Date(timeIntervalSince1970: 0), contentUpdatedDate: nil,
                         locationUpdatedDate: nil)
    }
}

extension OwnedKindRegistration {
    /// BookmarkKind registration.
    @MainActor
    static func bookmarks(access: any PhiBookmarkLocalAccess,
                          store: any PhiOwnedItemStateStore) -> OwnedKindRegistration {
        let state = BookmarkSyncRoundState()
        return OwnedKindRegistration(
            label: "bookmarks",
            tagPrefix: PhiSyncEntity.bookmarkTagPrefix,
            entityName: PhiSyncEntity.bookmarkEntityName,
            store: store,
            flags: .bookmarks,
            reportsAdoption: true,
            reportsScope: false,
            reportsRuleCounters: false,
            // Bookmarks and pins do not yield tombstones in this milestone and never enter the
            // round-end rule-3b recheck (sections 6.1/14.1).
            tombstoneYieldsToLocalEdits: false,
            landsEmptyBatch: false,
            identity: { envelope in
                guard let entity = BookmarkKind.entity(from: envelope) else { return nil }
                let identity = BookmarkKind.identity(of: entity)
                return identity.isEmpty ? nil : identity
            },
            clientTag: PhiSyncEntity.bookmarkClientTag,
            owners: { bytes in
                guard let envelope = try? Phi_PhiEntity(serializedBytes: bytes),
                      let entity = BookmarkKind.entity(from: envelope) else { return [] }
                return BookmarkKind.ownerUuids(of: entity)
            },
            // Bookmarks have no split partners; nil makes section 7.4 doctoring an identity
            // operation without any main-actor hop or loop.
            clearedSplitPartners: nil,
            beginRound: { state.reload(try access.allBookmarks()) },
            // Seed from all nonnil local syncIds, not the snapshot, so tombstones beneath orphan
            // roots remain routable (section 5.1). On read failure, fall back to the already-empty
            // round snapshot.
            localIdentities: {
                (try? access.allSyncIds()) ?? Set(state.locals.compactMap(\.syncId))
            },
            snapshot: { table, maps, now, hlcMax in
                bookmarkSnapshot(table: table, maps: maps, now: now, hlcMax: hlcMax,
                                 state: state)
            },
            tombstones: { table, maps, now in
                // Use allSyncIds as the deletion domain (R-exec-4). Snapshot excludes
                // orphan/duplicate-root subtrees even though their rows and identities still exist.
                // Using it would tombstone real account subtrees while leaving local rows intact.
                let live = try access.allSyncIds()
                // Exclude identities matched by this round's claims even if syncId write-back
                // failed (R-exec-9). Matching, not pendingApply, is the criterion: unmatched parked
                // cursors may legitimately require deletion. Successfully persisted matches already
                // appear in allSyncIds, so passing the full pair set is equivalent.
                return SyncableOwnedItems.tombstones(
                    BookmarkKind.self, locals: live.map(PhiLocalBookmark.identityOnly),
                    table: table, resolve: maps.resolver, scope: nil, nowMs: now,
                    pendingClaims: Set(state.pairs.keys))
            },
            retryParkedClaims: { parked, maps in
                await retryParkedBookmarkClaims(parked, maps: maps, access: access, state: state)
            },
            plan: { input in bookmarkPlan(input, state: state) },
            land: { input in await landBookmarks(input, access: access, state: state) },
            claimIdentities: { minted in
                await claimBookmarkIdentities(minted, access: access, state: state)
            },
            // Both pendingLocalEdit clearing hooks are URL-rule-only (section 8.4.5). Bookmark
            // registrations use no-op closures because their rows have no such field.
            notePublishApplied: { _ in },
            clearPendingLocalEdits: { _ in },
            // Retention condition (b) uses allSyncIds without root filtering (section 9.3 /
            // R-exec-4). Orphan-root rows remain live local claims even though snapshots never
            // publish them; their cursors need the same protection as any live row.
            liveOwners: { candidates, maps in
                let resolve = maps.resolver
                var out = OwnedLiveRows()
                out.claimed = try candidates.intersection(access.allSyncIds())
                // Use the same eligibilityOwner function as the publication pre-pass for rehoming,
                // so cascade and next-round refresh cannot disagree on the containing Space (A12 /
                // section 3.5).
                for row in state.locals {
                    guard let identity = row.syncId, out.claimed.contains(identity),
                          let owner = BookmarkKind.eligibilityOwner(of: row, resolve: resolve,
                                                                    scope: nil)
                    else { continue }
                    out.owners[identity] = owner
                }
                return out
            })
    }
}

/// Outbound snapshot and provisional identity minting in memory only (sections 4.2/6.4).
@MainActor
private func bookmarkSnapshot(table: PhiOwnedItemTable, maps: OwnedOwnerMaps, now: Int64,
                              hlcMax: Int64,
                              state: BookmarkSyncRoundState) -> OwnedSnapshotBytes {
    var out = OwnedSnapshotBytes()
    let resolve = maps.resolver
    // Mint provisional identities before snapshotting so both bookmark_uuid and child parent_uuid
    // refer to the same candidate; persist only after accepted commits (sections 4.2(2)/6.4). Do
    // not mint for rows already matched by section 6. Consult pairs, since the round-start locals
    // may still lack a newly claimed syncId; reminting would create an account entity with no local
    // owner.
    let claimedGuids = Set(state.pairs.values)
    var locals = state.locals
    for index in locals.indices
    where locals[index].syncId == nil && !claimedGuids.contains(locals[index].guid) {
        let identity = UUID().uuidString.lowercased()
        locals[index].syncId = identity
        out.minted[identity] = locals[index].guid
    }
    let result = SyncableOwnedItems.snapshot(BookmarkKind.self, locals: locals, table: table,
                                             resolve: resolve, scope: nil, now: now,
                                             hlcMax: hlcMax)
    out.skippedUnmappedOwner = result.skippedUnmappedOwner
    out.skippedIneligibleOwner = result.skippedIneligibleOwner
    for (identity, entity) in result.entities {
        guard let bytes = try? BookmarkKind.envelope(entity).serializedData() else { continue }
        out.entities[identity] = bytes
    }
    // Map identity to its current containing owner for the engine's per-round ownerUuid refresh
    // (A12 / section 3.5).
    for row in locals {
        guard let identity = row.syncId,
              let owner = BookmarkKind.eligibilityOwner(of: row, resolve: resolve, scope: nil)
        else { continue }
        out.ownerUuids[identity] = owner
    }
    // Discard minted candidates excluded from the snapshot by owner/ancestor eligibility. They
    // cannot commit this round and must not gain local identities through any non-applied path;
    // remint next round.
    out.minted = out.minted.filter { out.entities[$0.key] != nil }
    return out
}

/// Incoming planning and adoption (sections 4.4/6).
@MainActor
private func bookmarkPlan(_ input: OwnedPlanInput,
                          state: BookmarkSyncRoundState) -> OwnedPlanOutput {
    var out = OwnedPlanOutput()
    let resolve = input.maps.resolver
    var arrivals: [OwnedItemArrival<Phi_PhiBookmarkEntity>] = []
    for item in input.arrivals {
        guard let envelope = try? Phi_PhiEntity(serializedBytes: item.payload),
              let entity = BookmarkKind.entity(from: envelope) else { continue }
        arrivals.append(OwnedItemArrival(entity: entity, entityId: item.entityId,
                                         version: item.version))
        out.serverBytes[BookmarkKind.identity(of: entity)] = item.payload
        // Defer only owners with actual arrivals this round, not parked payloads from older rounds,
        // which could otherwise block local unsynced rows forever (section 5.3). Use
        // entity.space_uuid, not its parent reference. A descendant's stale Space UUID can at worst
        // delay an owner for one round; this is only an optimization, while stateless adoption
        // provides correctness (R-M3-3-18 / section 6.5).
        let spaceUuid = entity.spaceUuid.stringValue
        if !spaceUuid.isEmpty { out.deferredOwners.insert(spaceUuid) }
    }
    // D10 rule (i) never deletes or discards incoming entities. Include parked payloads in
    // continuous, stateless adoption (section 6.1), allowing accepted identities whose write-back
    // was blocked to reclaim the local row rather than create a duplicate next round.
    var candidates = arrivals.map(\.entity)
    let arrivedIdentities = Set(candidates.map(BookmarkKind.identity(of:)))
    for identity in input.parked.keys.sorted() where !arrivedIdentities.contains(identity) {
        guard let payload = input.parked[identity]?.payload,
              let envelope = try? Phi_PhiEntity(serializedBytes: payload),
              let entity = BookmarkKind.entity(from: envelope) else { continue }
        candidates.append(entity)
    }
    let adoption = SyncableOwnedItems.adopt(arrivals: candidates,
                                            locals: state.locals, resolve: resolve)
    var context = OwnedItemPlanContext()
    context.pairs = adoption.pairs
    context.adoptedMerges = adoption.merges
    context.adoptedFieldWrites = adoption.fieldWrites
    context.tombstonedIdentities = input.tombstoned
    context.localProjections = bookmarkLocalProjections(
        for: Set(arrivals.map { BookmarkKind.identity(of: $0.entity) })
            .union(input.parked.keys),
        table: input.table, resolve: resolve, now: input.now, state: state)
    context.liveLocalParents = Set(state.locals.filter(\.isFolder).compactMap(\.syncId))
    context.deletedSubtree = bookmarkDeletedSubtree(input.tombstoned, state: state)
    out.plan = SyncableOwnedItems.plan(BookmarkKind.self, arrivals: arrivals,
                                       parked: input.parked, table: input.table,
                                       resolve: resolve, context: context)
    state.mergePairs(adoption.pairs)
    out.adopted = adoption.adopted
    out.unmatchedFolders = adoption.unmatchedFolders
    out.unmergeablePairs = adoption.unmergeablePairs
    // Combine locally winning fields found by adoption and by normal planning; both require
    // republication (section 6.2).
    out.mustRepublish = adoption.mustRepublish.union(out.plan.mustRepublish)
    return out
}

/// Current local outbound projections for OwnedItemPlanContext. Use snapshot stamping with
/// BookmarkKind.stamp and the baseline: changed fields receive now, unchanged fields retain their
/// stamps (section 4.2(4)). Adoption's no-baseline contentUpdatedDate stamping could falsely make
/// untouched fields beat remote edits.
/// Fall back to baseline merging when the local row is absent, the cursor has no baseline, or the
/// parent lacks an identity. Without a baseline, unsynced location/rank stamps are zero; without a
/// parent identity, projecting at root would misrepresent the actual location.
@MainActor
private func bookmarkLocalProjections(for identities: Set<String>,
                                      table: PhiOwnedItemTable,
                                      resolve: OwnerResolver,
                                      now: Int64,
                                      state: BookmarkSyncRoundState) -> [String: Data] {
    var out: [String: Data] = [:]
    for identity in identities {
        guard let guid = state.identityToGuid[identity], let row = state.rowByGuid[guid],
              let baselineBytes = table.cursors[identity]?.reconciled,
              let baselineEnvelope = try? Phi_PhiEntity(serializedBytes: baselineBytes),
              let baseline = BookmarkKind.entity(from: baselineEnvelope) else { continue }
        var parentIdentity: String?
        if let parentGuid = row.parentGuid {
            guard let parent = state.rowByGuid[parentGuid]?.syncId else { continue }
            parentIdentity = parent
        }
        guard let projected = BookmarkKind.project(row, resolve: resolve, scope: nil,
                                                   parentIdentity: parentIdentity) else { continue }
        // Use baseline rank; snapshot assignRanks alone computes current outbound ordering. An
        // unpublished local-only reorder can lose to incoming rank this round, then publish as a
        // local change on the next snapshot, without running account ordering inside incoming
        // merge.
        let stamped = BookmarkKind.stamp(projected, baseline: baseline, local: row,
                                         rank: BookmarkKind.rank(of: baseline), now: now)
        guard let bytes = try? BookmarkKind.envelope(stamped).serializedData() else { continue }
        out[identity] = bytes
    }
    return out
}

/// Write claimed identities per Space (section 6.4). A fail-closed import lock on one Space must
/// not block already accepted identities in another. Return only successfully persisted identities.
@MainActor
private func claimBookmarkIdentities(_ pairs: [String: String],
                                     access: any PhiBookmarkLocalAccess,
                                     state: BookmarkSyncRoundState) async -> Set<String> {
    var bySpace: [String: [BookmarkApplyOp]] = [:]
    var identitiesBySpace: [String: Set<String>] = [:]
    for (identity, guid) in pairs.sorted(by: { $0.key < $1.key }) {
        let spaceId = state.rowByGuid[guid]?.spaceId ?? ""
        bySpace[spaceId, default: []].append(.claim(guid: guid, syncId: identity))
        identitiesBySpace[spaceId, default: []].insert(identity)
    }
    var persisted: Set<String> = []
    for spaceId in bySpace.keys.sorted() {
        guard let ops = bySpace[spaceId], !ops.isEmpty else { continue }
        do {
            try await access.apply(BookmarkApplyBatch(unordered: ops))
            persisted.formUnion(identitiesBySpace[spaceId] ?? [])
        } catch {
            AppLogError("[phi-sync] bookmark identities could not be written back "
                        + "count=\(ops.count) (\(PhiSyncLog.describe(error)))")
        }
    }
    return persisted
}

/// Bookmark parked-claim retry (section 3 / R-exec-10): rerun section 6 adoption and persist
/// matches before any round's snapshot/diff, including pure pushes. Keep unmatched payloads parked
/// for retry; if no local row can claim them, deletion diff provides cleanup (R-exec-9).
@MainActor
private func retryParkedBookmarkClaims(_ parked: [String: ParkedOwnedItem],
                                       maps: OwnedOwnerMaps,
                                       access: any PhiBookmarkLocalAccess,
                                       state: BookmarkSyncRoundState) async
    -> OwnedParkedClaimResult {
    var out = OwnedParkedClaimResult()
    var entities: [Phi_PhiBookmarkEntity] = []
    for identity in parked.keys.sorted() {
        guard let payload = parked[identity]?.payload,
              let envelope = try? Phi_PhiEntity(serializedBytes: payload),
              let entity = BookmarkKind.entity(from: envelope) else { continue }
        entities.append(entity)
    }
    guard !entities.isEmpty else { return out }
    let adoption = SyncableOwnedItems.adopt(arrivals: entities, locals: state.locals,
                                            resolve: maps.resolver)
    guard !adoption.pairs.isEmpty else { return out }
    out.paired = Set(adoption.pairs.keys)
    state.mergePairs(adoption.pairs)
    out.persisted = await claimBookmarkIdentities(adoption.pairs, access: access, state: state)
    var persistedPairs: [String: String] = [:]
    for identity in out.persisted {
        guard let guid = adoption.pairs[identity] else { continue }
        persistedPairs[identity] = guid
    }
    state.notePersistedClaims(persistedPairs)
    return out
}

/// A9's third conjunct: identities disappearing under remote folder tombstones this round.
@MainActor
private func bookmarkDeletedSubtree(_ tombstoned: Set<String>,
                                    state: BookmarkSyncRoundState) -> Set<String> {
    var childrenOf: [String: [PhiLocalBookmark]] = [:]
    for row in state.locals {
        guard let parent = row.parentGuid else { continue }
        childrenOf[parent, default: []].append(row)
    }
    var out: Set<String> = []
    var stack = tombstoned.compactMap { state.identityToGuid[$0] }
    var hops = 0
    let limit = state.locals.count * 2 + 1
    while let guid = stack.popLast(), hops < limit {
        hops += 1
        for child in childrenOf[guid] ?? [] {
            if let identity = child.syncId { out.insert(identity) }
            stack.append(child.guid)
        }
    }
    return out
}

/// Bookmark landing (sections 4.4/4.5): split by Space, project ranks to indices, apply three-phase
/// batches, then recheck.
@MainActor
private func landBookmarks(_ input: OwnedLandingInput,
                           access: any PhiBookmarkLocalAccess,
                           state: BookmarkSyncRoundState) async -> OwnedLandingOutcome {
    var outcome = OwnedLandingOutcome()
    guard !input.steps.isEmpty else { return outcome }
    let resolve = input.maps.resolver

    struct Planned {
        var step: OwnedItemApplyStep
        var entity: Phi_PhiBookmarkEntity?
    }
    var planned: [Planned] = []
    for step in input.steps {
        let entity = step.payload.flatMap { bytes -> Phi_PhiBookmarkEntity? in
            guard let envelope = try? Phi_PhiEntity(serializedBytes: bytes) else { return nil }
            return BookmarkKind.entity(from: envelope)
        }
        planned.append(Planned(step: step, entity: entity))
    }

    // Identity to the local GUID used this round.
    var guidOf: [String: String] = [:]
    for item in planned {
        if let guid = state.pairs[item.step.identity] ?? state.identityToGuid[item.step.identity] {
            guidOf[item.step.identity] = guid
        }
    }

    // No fallback for a claim targeting an already claimed row is needed here (section 6.1 / CASE
    // 6b.13). Adoption considers only syncId-nil local children and pairs one-to-one; a second
    // same-key arrival becomes create. bookmarkPlan merges pairs into state, and rowByGuid stays
    // synchronized through reload/notePersistedClaims.
    // The real store's rowAlreadyMapped guard is defense in depth against a previously mapped
    // target, not the pairing rule itself. Real storage applies operations sequentially, while the
    // fake prechecks original rows and would not catch two claims to the same initially unmapped
    // row. Preserve the actual one-to-one adoption invariant rather than adding unreachable repair
    // code.

    // Check physical row type (section 4.6), which baseline-only refuses cannot establish when no
    // baseline exists. Converting a bookmark to a folder discards URL semantics; converting a
    // folder to a bookmark would orphan its children.
    var work: [Planned] = []
    for item in planned {
        if let entity = item.entity, let guid = guidOf[item.step.identity],
           let isFolder = access.localIsFolder(guid: guid), isFolder != entity.isFolder {
            outcome.refused.insert(item.step.identity)
            continue
        }
        work.append(item)
    }
    // Premint GUIDs for earlier creates so later children can resolve their parent.
    for item in work where item.step.kind == .create && guidOf[item.step.identity] == nil {
        guidOf[item.step.identity] = UUID().uuidString
    }
    guard !work.isEmpty else { return outcome }

    let deletedIdentities = Set(work.filter { $0.step.kind == .delete }.map(\.step.identity))
    let deletedGuids = Set(deletedIdentities.compactMap { guidOf[$0] })

    // Start from the round snapshot and apply planned locations to an in-memory projection. It also
    // resolves the parent's Space; every child shares its parent's Space.
    var projected = state.rowByGuid
    var rankOf: [String: String] = [:]
    for (identity, cursor) in input.table.cursors {
        guard let bytes = cursor.reconciled,
              let envelope = try? Phi_PhiEntity(serializedBytes: bytes),
              let entity = BookmarkKind.entity(from: envelope) else { continue }
        rankOf[identity] = BookmarkKind.rank(of: entity)
    }

    var placed: [(item: Planned, guid: String, group: BookmarkSiblingGroup)] = []
    var touched: Set<BookmarkSiblingGroup> = []
    var parentOf: [String: String] = [:]
    var payloadOf: [String: Data] = [:]

    for item in work {
        let identity = item.step.identity
        if let payload = item.step.payload { payloadOf[identity] = payload }
        if let rank = item.step.newRank { rankOf[identity] = rank }

        // Section 5.6 T3: a known identity with no local row requires no physical deletion but
        // still finalizes deletedAtMs. Handle before requiring guidOf, because absence is exactly
        // the case that lacks a GUID. Otherwise its cursor never expires and this round emits a
        // redundant tombstone.
        let resolvedGuid = guidOf[identity]
        if item.step.kind == .delete, resolvedGuid.flatMap({ projected[$0] }) == nil {
            outcome.landed.insert(identity)
            outcome.deleted.insert(identity)
            continue
        }
        guard let guid = resolvedGuid else { continue }

        if item.step.kind == .update || item.step.kind == .delete {
            guard let row = projected[guid] else { continue }
            placed.append((item, guid, BookmarkSiblingGroup(spaceId: row.spaceId,
                                                            parentGuid: row.parentGuid)))
            continue
        }

        guard let entity = item.entity else { continue }
        // A nil newParentUuid means use the payload's parent_uuid, not move to Space root. Non-nil
        // overrides are supplied only when planning chose the parent, including an empty string for
        // root or a parent in the same batch.
        let parentIdentity = item.step.newParentUuid ?? entity.parentUuid.stringValue
        var group: BookmarkSiblingGroup
        if parentIdentity.isEmpty {
            guard let spaceId = resolve.localSpaceId(entity.spaceUuid.stringValue) else {
                outcome.parked.insert(identity)
                continue
            }
            group = BookmarkSiblingGroup(spaceId: spaceId, parentGuid: nil)
        } else {
            guard let parentGuid = guidOf[parentIdentity] ?? state.identityToGuid[parentIdentity],
                  let parentRow = projected[parentGuid] else {
                outcome.parked.insert(identity)
                continue
            }
            group = BookmarkSiblingGroup(spaceId: parentRow.spaceId, parentGuid: parentGuid)
            parentOf[guid] = parentGuid
        }

        if var row = projected[guid] {
            // Find the local row by syncId before creating (section 4.5). Replay, adoption and
            // ordinary updates depend on this; blindly executing a planned create would duplicate
            // every existing bookmark after replay.
            row.syncId = identity
            row.spaceId = group.spaceId
            row.parentGuid = group.parentGuid
            projected[guid] = row
        } else {
            projected[guid] = PhiLocalBookmark(
                syncId: identity, guid: guid, spaceId: group.spaceId,
                // The Space's own Profile first (review A4): a row created under any other
                // Profile has no root to land in — `existingBookmarkRoot` matches on both ids —
                // and the whole Space's batch parks on every round. The sibling and default
                // fallbacks only remain for a Space the owner map did not describe.
                profileId: resolve.localProfileIdForSpace(group.spaceId)
                    ?? state.locals.first { $0.spaceId == group.spaceId }?.profileId
                    ?? LocalStore.defaultProfileId,
                parentGuid: group.parentGuid, index: 0, isFolder: entity.isFolder,
                title: entity.title.stringValue,
                url: URL(string: entity.url.stringValue)
                    ?? URL(string: "https://bookmark.phi/folder")!,
                secondaryUrl: URL(string: entity.secondaryURL.stringValue),
                secondaryTitle: entity.secondaryTitle.stringValue.isEmpty
                    ? nil : entity.secondaryTitle.stringValue,
                source: Int(entity.source),
                createdDate: Date(timeIntervalSince1970: Double(entity.createdAtMs) / 1000),
                contentUpdatedDate: nil, locationUpdatedDate: nil)
        }
        touched.insert(group)
        placed.append((item, guid, group))
    }

    // R-M3-3-17's three steps: step 2 must be a no-op for an empty set (CASE 6.10c).
    var childrenOf: [String: [String]] = [:]
    for (guid, row) in projected {
        guard let parent = row.parentGuid else { continue }
        childrenOf[parent, default: []].append(guid)
    }
    for guid in deletedGuids where projected[guid]?.isFolder == true {
        var stack = childrenOf[guid] ?? []
        var hops = 0
        while let child = stack.popLast(), hops <= projected.count {
            hops += 1
            stack.append(contentsOf: childrenOf[child] ?? [])
            guard !deletedGuids.contains(child), var row = projected[child] else { continue }
            // Lift every remaining descendant to its Space root before deleting the folder itself
            // in phase 3.
            row.parentGuid = nil
            projected[child] = row
            parentOf.removeValue(forKey: child)
            touched.insert(BookmarkSiblingGroup(spaceId: row.spaceId, parentGuid: nil))
        }
    }
    for guid in deletedGuids { projected.removeValue(forKey: guid) }

    // Project rank to index here, where all incoming ranks are available, not in local access
    // (section 4.10 / R-exec-2). Moves must emit a full sibling permutation: the batch writer
    // assigns raw indices and does not shift untouched siblings automatically.
    var indexOf: [String: Int] = [:]
    for group in touched {
        var members = access.siblings(ofParent: group.parentGuid, inSpaceId: group.spaceId)
            .compactMap { projected[$0.guid] }
            .filter { $0.spaceId == group.spaceId && $0.parentGuid == group.parentGuid }
        for (guid, row) in projected where row.spaceId == group.spaceId
            && row.parentGuid == group.parentGuid
            && !members.contains(where: { $0.guid == guid }) {
            members.append(row)
        }
        for (guid, index) in BookmarkKind.rankToIndex(siblings: members, ranks: rankOf) {
            indexOf[guid] = index
        }
    }

    var opsBySpace: [String: [BookmarkApplyOp]] = [:]
    var identitiesBySpace: [String: Set<String>] = [:]
    // Only create and move operations already carry final indices. Claims write identity and
    // updates write fields, so both must join the remaining permutation. Otherwise a rename/claim
    // can retain an old index while siblings are renumbered, creating unstable duplicate positions.
    var indexed: Set<String> = []
    // Track genuinely new rows; successful post-landing checks pass them to favicon backfill
    // (section 8.2 / Task 10).
    var createdRowsByIdentity: [String: PhiLocalBookmark] = [:]
    func emit(_ op: BookmarkApplyOp, in spaceId: String) {
        opsBySpace[spaceId, default: []].append(op)
    }

    for entry in placed {
        let identity = entry.item.step.identity
        identitiesBySpace[entry.group.spaceId, default: []].insert(identity)
        switch entry.item.step.kind {
        case .claim:
            emit(.claim(guid: entry.guid, syncId: identity), in: entry.group.spaceId)
        case .create:
            if state.identityToGuid[identity] != nil || state.pairs[identity] != nil {
                // An existing identity is replay/adoption, not a new row.
                emit(.move(guid: entry.guid, toParentGuid: entry.group.parentGuid,
                           inSpaceId: entry.group.spaceId, index: indexOf[entry.guid] ?? 0),
                     in: entry.group.spaceId)
                indexed.insert(entry.guid)
                if let entity = entry.item.entity {
                    emit(.update(guid: entry.guid, fields: bookmarkPatch(entity)),
                         in: entry.group.spaceId)
                }
            } else if var row = projected[entry.guid] {
                row.index = indexOf[entry.guid] ?? 0
                emit(.create(row), in: entry.group.spaceId)
                createdRowsByIdentity[identity] = row
                indexed.insert(entry.guid)
            }
        case .move:
            emit(.move(guid: entry.guid, toParentGuid: entry.group.parentGuid,
                       inSpaceId: entry.group.spaceId, index: indexOf[entry.guid] ?? 0),
                 in: entry.group.spaceId)
            indexed.insert(entry.guid)
        case .update:
            if let entity = entry.item.entity {
                emit(.update(guid: entry.guid, fields: bookmarkPatch(entity)),
                     in: entry.group.spaceId)
            }
        case .transfer:
            // Only URL rules produce edit-transfer steps under tombstone yielding (section 8.4.4 /
            // 8b-3 ruling 10). This is unreachable for bookmarks; skip rather than invent bookmark
            // semantics.
            continue
        case .delete:
            emit(.delete(guid: entry.guid), in: entry.group.spaceId)
        }
    }
    // Emit the remaining existing siblings in ascending final-index order for deterministic fetch
    // results, including claimed, renamed and otherwise untouched rows.
    for group in touched {
        let movers = projected.values
            .filter { $0.spaceId == group.spaceId && $0.parentGuid == group.parentGuid
                && !indexed.contains($0.guid) && state.rowByGuid[$0.guid] != nil }
            .sorted { (indexOf[$0.guid] ?? 0, $0.guid) < (indexOf[$1.guid] ?? 0, $1.guid) }
        for row in movers {
            emit(.move(guid: row.guid, toParentGuid: group.parentGuid,
                       inSpaceId: group.spaceId, index: indexOf[row.guid] ?? row.index),
                 in: group.spaceId)
        }
    }

    // Split landing into one transaction per touched Space so a fail-closed import lock in one
    // cannot roll back unrelated Spaces. Parent/child rows always share a Space. Only refresh from
    // access after at least one batch actually applied, preserving the one-fetch rule for
    // no-landing rounds.
    var didApply = false
    for spaceId in opsBySpace.keys.sorted() {
        let ops = opsBySpace[spaceId] ?? []
        guard !ops.isEmpty else { continue }
        let identities = identitiesBySpace[spaceId] ?? []
        do {
            try await access.apply(BookmarkApplyBatch(unordered: ops, parentOf: parentOf))
            didApply = true
        } catch LocalStoreWriteError.folderNotEmpty, LocalStoreWriteError.rowAlreadyMapped {
            // Refuse an invalid batch plan rather than parking it for identical, permanently
            // failing retries.
            outcome.refused.formUnion(identities)
            continue
        } catch {
            // Park import-lock and other transient failures for the next round.
            outcome.parked.formUnion(identities)
            continue
        }
        // Recheck the plan after landing but before baseline updates (section 4.5). apply rebuilds
        // its cache, so these reads observe post-landing rows and cannot silently count a refused
        // write as success.
        for identity in identities {
            guard let guid = guidOf[identity] else { continue }
            let known = access.isKnownLocalBookmark(guid)
            if deletedIdentities.contains(identity) {
                if known { outcome.parked.insert(identity) } else {
                    outcome.landed.insert(identity)
                    outcome.deleted.insert(identity)
                }
                continue
            }
            guard known else { outcome.parked.insert(identity); continue }
            outcome.landed.insert(identity)
            // New rows have no favicon by construction; submit them for backfill (section 8.2 /
            // Task 10).
            if let created = createdRowsByIdentity[identity] { outcome.createdRows.append(created) }
            if let payload = payloadOf[identity] { outcome.reconciled[identity] = payload }
        }
    }
    outcome.parked.subtract(outcome.landed)
    outcome.refused.subtract(outcome.landed)
    // Immediately remove deleted rows from the round projection so publication cannot resurrect
    // them (CASE 6b.8).
    state.noteDeletedRows(Set(outcome.deleted.compactMap { guidOf[$0] }))
    // After any successful batch, refresh from access's rebuilt cache before outbound snapshotting,
    // without another fetch (Step 3). Otherwise stale pre-landing values differ from reconciled,
    // causing redundant commits stamped with a newer now that can overwrite genuine remote edits
    // (CASE 7.6/7.7). Nil means the post-apply read failed: retain the existing projection rather
    // than replace it with an empty snapshot.
    if didApply, let refreshed = access.cachedBookmarks() {
        state.refreshLandedRows(refreshed)
    }
    return outcome
}

/// Convert the entity's four content fields to one local field patch.
@MainActor
private func bookmarkPatch(_ entity: Phi_PhiBookmarkEntity) -> BookmarkFieldPatch {
    BookmarkFieldPatch(
        title: .some(entity.title.stringValue),
        url: .some(URL(string: entity.url.stringValue)),
        secondaryUrl: .some(URL(string: entity.secondaryURL.stringValue)),
        secondaryTitle: .some(entity.secondaryTitle.stringValue.isEmpty
                              ? nil : entity.secondaryTitle.stringValue))
}

// MARK: - PinKind adapter

/// Main-actor pin state mirrors BookmarkSyncRoundState without adoption pairs: pin identity derives
/// from lineage/owner, so no local syncId mint/write-back exists (section 6.7). Keep
/// compiler-enforced MainActor isolation for all local access and doctoring callbacks, including
/// future mid-round writers. Serialized rounds alone are not a substitute for that isolation
/// guarantee.
@MainActor
final class PinSyncRoundState {
    /// The round-start allPins() snapshot: every active, non-dormant row in the current scope.
    private(set) var locals: [PhiLocalPin] = []
    private(set) var rowByGuid: [String: PhiLocalPin] = [:]
    /// Capture both section 7.3 scopes once at round start. Nil account scope means not yet
    /// published and does not count as a mismatch.
    private(set) var localScope: PinnedTabScope = .profile
    private(set) var accountScope: PinnedTabScope?

    /// If both scopes are known and differ, skip all pin publication and park all incoming pins
    /// this round (section 7.3).
    var scopeMismatch: Bool {
        guard let accountScope else { return false }
        return localScope != accountScope
    }

    /// Whether either scope changed after the initial sample (R-exec-12); see rescanScopes.
    private(set) var scopeMovedMidRound = false

    /// Block when scopes initially mismatched or changed mid-round. All publication guards and
    /// landing share this predicate (section 7.3).
    var scopeBlocked: Bool { scopeMismatch || scopeMovedMidRound }

    func reload(_ rows: [PhiLocalPin], localScope: PinnedTabScope,
                accountScope: PinnedTabScope?) {
        locals = rows
        rowByGuid = [:]
        for row in rows { rowByGuid[row.guid] = row }
        self.localScope = localScope
        self.accountScope = accountScope
        // Reset the flag at each round start; this registration-owned state is reused, so a sticky
        // cross-round flag would disable pin sync forever after one migration.
        scopeMovedMidRound = false
    }

    /// Resample both scopes after round start (R-exec-12 / D-A). Incoming settings can trigger
    /// detached scope migration after locals were captured but before pin landing, replacing
    /// physical rows while cached identities still describe the old scope. Landing against that
    /// cache would duplicate migrated pins.
    /// Set a sticky round flag without replacing the original scope values: those values still
    /// interpret the cached rows. Even a change back leaves the cache suspect. Skip this round; the
    /// next beginRound reads consistent new rows and scopes.
    func rescanScopes(localScope: PinnedTabScope, accountScope: PinnedTabScope?) {
        guard localScope != self.localScope || accountScope != self.accountScope else { return }
        scopeMovedMidRound = true
    }

    /// Refresh from access's post-landing cache without a second fetch, matching
    /// BookmarkSyncRoundState (Step 3). Keep both originally sampled scopes unchanged for the
    /// section 7.3 checks.
    func refreshLandedRows(_ rows: [PhiLocalPin]) {
        locals = rows
        rowByGuid = [:]
        for row in rows { rowByGuid[row.guid] = row }
    }

    /// Remove actually deleted rows from the round projection immediately, preventing rule 3b from
    /// republishing a just-deleted remote pin in the same round.
    func noteDeletedRows(_ guids: Set<String>) {
        guard !guids.isEmpty else { return }
        for guid in guids { rowByGuid.removeValue(forKey: guid) }
        locals.removeAll { guids.contains($0.guid) }
    }

    /// Reflect persisted split links in the in-memory projection without another fetch. Otherwise
    /// snapshot doctoring would see the newly accepted baseline link but an old unlinked local row,
    /// misclassify it as a local unlink, and split the peer's pair in the same round.
    func noteSplitPartnerWrites(linked: [String: String], cleared: Set<String>) {
        guard !linked.isEmpty || !cleared.isEmpty else { return }
        for index in locals.indices {
            let guid = locals[index].guid
            if let partner = linked[guid] {
                locals[index].splitPartnerLineageId = partner
            } else if cleared.contains(guid) {
                locals[index].splitPartnerLineageId = nil
            } else {
                continue
            }
            rowByGuid[guid] = locals[index]
        }
    }

    /// Whether the exact account identity still has a local split link (section 7.4). Check full
    /// identity, not lineage: different owners can legitimately have linked and unlinked variants.
    /// Scan linked rows only, which are a small subset.
    func stillCarriesSplitLink(_ identity: String, maps: OwnedOwnerMaps) -> Bool {
        let resolve = maps.resolver
        for row in locals where row.splitPartnerLineageId != nil {
            if PinKind.identity(of: row, resolve: resolve, scope: localScope) == identity {
                return true
            }
        }
        return false
    }
}

/// Split pin identity lineage:ownerKey at the first colon. isNormalizedLineage rejects colons so
/// the composition remains reversible and cannot alias distinct lineage/owner pairs.
func pinIdentityHalves(_ identity: String) -> (lineage: String, ownerKey: String) {
    guard let separator = identity.firstIndex(of: ":") else { return (identity, "") }
    return (String(identity[..<separator]),
            String(identity[identity.index(after: separator)...]))
}

/// Build the client tag through pinClientTag(lineageKey(...), ownerKey:) (section 2.5). The
/// lower-level tag function does not normalize case; callers own normalization (section 3.2), or
/// receiver hash validation would reject every such entity.
func pinClientTag(for identity: String) -> String {
    let halves = pinIdentityHalves(identity)
    return PhiSyncEntity.pinClientTag(PinKind.lineageKey(halves.lineage),
                                      ownerKey: halves.ownerKey)
}

/// Batch pin baseline doctoring in one main-actor hop per kind per round (section 7.4). Return only
/// genuinely modified baselines; missing entries keep their original bytes.
@MainActor
func clearedPinSplitPartners(_ baselines: [String: Data], now: Int64, maps: OwnedOwnerMaps,
                             state: PinSyncRoundState) -> [String: Data] {
    var out: [String: Data] = [:]
    for (identity, bytes) in baselines {
        guard let cleared = clearedPinSplitPartner(bytes, now: now, maps: maps, state: state)
        else { continue }
        out[identity] = cleared
    }
    return out
}

/// Clear a genuinely removed split partner in the snapshot-only baseline and stamp it with this
/// round's now (section 7.4). PinKind.stamp compares value signatures, so empty projection versus
/// newly emptied baseline otherwise retains the old stamp. At equal timestamps, proto3's omitted
/// empty field loses the serialized-byte tie to a nonempty link, repeatedly restoring the split.
/// Return nil for non-pin bytes, an already empty partner, or a local row that still carries its
/// link. Do not clear intact pairs merely because pendingPartnerLineage is nil: they also finished
/// waiting. Doing so would restamp/rebroadcast every intact pair each round, consuming the
/// publication budget on both devices.
@MainActor
func clearedPinSplitPartner(_ bytes: Data, now: Int64, maps: OwnedOwnerMaps,
                            state: PinSyncRoundState) -> Data? {
    guard let envelope = try? Phi_PhiEntity(serializedBytes: bytes),
          var entity = PinKind.entity(from: envelope),
          !entity.splitPartnerUuid.stringValue.isEmpty else { return nil }
    // A locally intact link is not an unlink; preserve its bytes.
    guard !state.stillCarriesSplitLink(PinKind.identity(of: entity), maps: maps) else {
        return nil
    }
    var cleared = Phi_PhiSettingValue()
    cleared.stringValue = ""
    cleared.updatedAtMs = now
    entity.splitPartnerUuid = cleared
    return try? PinKind.envelope(entity).serializedData()
}

extension OwnedKindRegistration {
    /// PinKind registration.
    @MainActor
    static func pins(access: any PhiPinnedTabLocalAccess,
                     store: any PhiOwnedItemStateStore) -> OwnedKindRegistration {
        let state = PinSyncRoundState()
        return OwnedKindRegistration(
            label: "pins",
            tagPrefix: PhiSyncEntity.pinTagPrefix,
            entityName: PhiSyncEntity.pinEntityName,
            store: store,
            flags: .pins,
            // Adoption counters belong only to bookmarks; pins do not use section 6 adoption
            // (sections 11.2/6.7).
            reportsAdoption: false,
            // Only pin counters expose relineaged and scope_mismatch.
            reportsScope: true,
            reportsRuleCounters: false,
            // Bookmarks and pins do not yield tombstones or enter the rule-3b recheck in this
            // milestone (sections 6.1/14.1).
            tombstoneYieldsToLocalEdits: false,
            landsEmptyBatch: false,
            identity: { envelope in
                guard let entity = PinKind.entity(from: envelope) else { return nil }
                let identity = PinKind.identity(of: entity)
                return identity.isEmpty ? nil : identity
            },
            clientTag: pinClientTag(for:),
            owners: { bytes in
                guard let envelope = try? Phi_PhiEntity(serializedBytes: bytes),
                      let entity = PinKind.entity(from: envelope) else { return [] }
                return PinKind.ownerUuids(of: entity)
            },
            clearedSplitPartners: { baselines, now, maps in
                clearedPinSplitPartners(baselines, now: now, maps: maps, state: state)
            },
            beginRound: {
                state.reload(try access.allPins(),
                             localScope: access.currentScope(),
                             accountScope: access.accountScope())
            },
            // Pin tag indices seed from cursor keys only (section 5.1). This callback lacks round
            // owner mappings and the throwing allPinRows read; raw lineage cannot construct valid
            // account tags. An empty local seed is conservative: unknown tombstones for lost
            // cursors rely on the existing full-type replay recovery (R-M3-3-13).
            localIdentities: { [] },
            snapshot: { table, maps, now, hlcMax in
                pinSnapshot(table: table, maps: maps, now: now, hlcMax: hlcMax, access: access,
                            state: state)
            },
            tombstones: { table, maps, now in
                try pinTombstones(table: table, maps: maps, now: now,
                                  access: access, state: state)
            },
            // Pins have no claim matching or identity write-back (section 6.7). Keep a no-op
            // callback so generic engine retry code needs no kind-specific branch (R-exec-10).
            retryParkedClaims: { _, _ in OwnedParkedClaimResult() },
            plan: { input in pinPlan(input, access: access, state: state) },
            land: { input in await landPins(input, access: access, state: state) },
            // No minting means no identity write-back; pin snapshots always have an empty minted
            // map.
            claimIdentities: { _ in [] },
            // Both section 8.4.5 flag-clearing hooks are URL-rule-only; pins use no-op callbacks.
            notePublishApplied: { _ in },
            clearPendingLocalEdits: { _ in },
            // Retention claims use full lineage:ownerKey identities, matching pinTombstones
            // (section 9.3). Current-scope rows claim exact derived identities and provide current
            // owners. Extra allPinRows backup rows outside allPins claim only their own identities
            // without rehoming (R-exec-4/11). Only unresolved owners in that backup set fall back
            // to lineage protection under A12.
            // Using lineage for all rows would let a different owner's variant indefinitely protect
            // an obsolete cursor pointing at a purged Space. Changing owner requires tombstoning
            // the old identity and creating the new one (section 7.2), not claiming both (T9a-2).
            liveOwners: { candidates, maps in
                let resolve = maps.resolver
                let scope = state.localScope
                let fullStoreRows = try access.allPinRows()
                // Use eligibilityOwner, not the identity suffix, which can be an unresolved-owner
                // placeholder and must never be persisted as ownership.
                var ownerByIdentity: [String: String] = [:]
                for row in state.locals {
                    guard let identity = PinKind.identity(of: row, resolve: resolve, scope: scope),
                          let owner = PinKind.eligibilityOwner(of: row, resolve: resolve,
                                                               scope: scope)
                    else { continue }
                    ownerByIdentity[identity] = owner
                }
                // Second claim source matches pinTombstones: full-store rows absent from the round
                // projection each contribute their own identity (R-exec-11).
                let claimedGuids = Set(state.locals.map(\.guid))
                var outOfScopeIdentities: Set<String> = []
                // For backup rows with unresolved owners, conservatively protect by lineage (A12).
                // Query eligibilityOwner, not identity(of:), which returns a NUL-prefixed
                // placeholder rather than nil. Unresolved ownership cannot prove a live row is
                // unrelated to a cursor; deleting that cursor risks a blind create overwrite,
                // whereas keeping it only extends retention. Apply this fallback only to source 2;
                // current-scope rows retain their exact-identity behavior.
                var unresolvedOwnerLineages: Set<String> = []
                for row in fullStoreRows where !claimedGuids.contains(row.guid) {
                    guard let identity = PinKind.identity(of: row, resolve: resolve, scope: scope)
                    else { continue }
                    guard PinKind.eligibilityOwner(of: row, resolve: resolve, scope: scope) != nil
                    else {
                        unresolvedOwnerLineages.insert(PinKind.lineageKey(row.lineageId))
                        continue
                    }
                    outOfScopeIdentities.insert(identity)
                }
                var out = OwnedLiveRows()
                for identity in candidates {
                    if let owner = ownerByIdentity[identity] {
                        out.claimed.insert(identity)
                        out.owners[identity] = owner
                        continue
                    }
                    // Backup rows claim their own full identities, except the explicit
                    // unresolved-owner lineage fallback. Do not rehome them; only source 1 supplies
                    // current ownerUuid values.
                    guard outOfScopeIdentities.contains(identity)
                            || unresolvedOwnerLineages.contains(
                                pinIdentityHalves(identity).lineage)
                    else { continue }
                    out.claimed.insert(identity)
                }
                return out
            })
    }
}

/// Outbound pin snapshot (section 4.2). Identity derives from lineage/owner, so no provisional
/// minting or later identity write-back is needed; section 6.4 is a no-op for pins.
@MainActor
private func pinSnapshot(table: PhiOwnedItemTable, maps: OwnedOwnerMaps, now: Int64,
                         hlcMax: Int64,
                         access: any PhiPinnedTabLocalAccess,
                         state: PinSyncRoundState) -> OwnedSnapshotBytes {
    var out = OwnedSnapshotBytes()
    // Resample scopes before publication (R-exec-12). A pure push has no plan or landing path, so
    // this is its only recheck.
    state.rescanScopes(localScope: access.currentScope(), accountScope: access.accountScope())
    // On blocked scopes, skip all pin snapshot/publication work and return an empty snapshot; plan
    // parks the incoming half (section 7.3). Carry scope_mismatch diagnostics from here too,
    // because a pure push never runs plan (section 11.2).
    guard !state.scopeBlocked else {
        out.scopeMismatch = true
        return out
    }
    let resolve = maps.resolver
    let scope = state.localScope
    let result = SyncableOwnedItems.snapshot(PinKind.self, locals: state.locals, table: table,
                                             resolve: resolve, scope: scope, now: now,
                                             hlcMax: hlcMax)
    out.skippedUnmappedOwner = result.skippedUnmappedOwner
    out.skippedIneligibleOwner = result.skippedIneligibleOwner
    for (identity, entity) in result.entities {
        guard let bytes = try? PinKind.envelope(entity).serializedData() else { continue }
        out.entities[identity] = bytes
    }
    // Map identity to its actual current eligibilityOwner for cursor refresh (A12 / section 3.5).
    // Never use an identity suffix that may contain an unresolved-owner placeholder.
    for row in state.locals {
        guard let identity = PinKind.identity(of: row, resolve: resolve, scope: scope),
              let owner = PinKind.eligibilityOwner(of: row, resolve: resolve, scope: scope)
        else { continue }
        out.ownerUuids[identity] = owner
    }
    return out
}

/// Pin deletion diff (section 4.7).
@MainActor
private func pinTombstones(table: PhiOwnedItemTable, maps: OwnedOwnerMaps, now: Int64,
                           access: any PhiPinnedTabLocalAccess,
                           state: PinSyncRoundState) throws -> OwnedItemTombstoneResult {
    // Resample before allPinRows (R-exec-12). Mid-round migration invalidates access's cache
    // without rereading it, and this round should be skipped rather than throw while reading that
    // stale cache.
    state.rescanScopes(localScope: access.currentScope(), accountScope: access.accountScope())
    // Deletion diff is part of the publication half suppressed by scope mismatch (section 7.3).
    guard !state.scopeBlocked else {
        return OwnedItemTombstoneResult(identities: [], cursorUpdates: [:])
    }
    let resolve = maps.resolver
    let scope = state.localScope
    // Use the full-store allPinRows domain, not the snapshot (R-exec-4). A failed read throws and
    // skips publication; interpreting failure as empty would tombstone every published identity.
    let fullStoreRows = try access.allPinRows()
    // Domain is the refreshed current-scope projection plus full-store rows it does not cover,
    // deduplicated by GUID in favor of the post-landing projection. Each row contributes its own
    // lineage/owner identity (R-exec-11), matching snapshot derivation. A Profile backup protects
    // its Profile identity, not the same lineage's old Space identity; changing owners is
    // old-delete plus new-create. Broad lineage-only protection previously swallowed legitimate
    // unpin deletions.
    var domain = state.locals
    let claimedGuids = Set(state.locals.map(\.guid))
    for row in fullStoreRows where !claimedGuids.contains(row.guid) {
        domain.append(row)
    }
    // Pins have no matched-but-unpersisted adoption state, so pendingClaims is empty (R-exec-9).
    return SyncableOwnedItems.tombstones(PinKind.self, locals: domain, table: table,
                                         resolve: resolve, scope: scope, nowMs: now,
                                         pendingClaims: [])
}

/// Incoming pin planning (section 4.4), without section 6 adoption: initial sync unions pins from
/// both devices (section 6.7).
@MainActor
private func pinPlan(_ input: OwnedPlanInput, access: any PhiPinnedTabLocalAccess,
                     state: PinSyncRoundState) -> OwnedPlanOutput {
    var out = OwnedPlanOutput()
    // Resample before building plan context (R-exec-12). If scopes changed, park every incoming
    // entity until next round captures consistent rows and scopes.
    state.rescanScopes(localScope: access.currentScope(), accountScope: access.accountScope())
    var arrivals: [OwnedItemArrival<Phi_PhiPinTabEntity>] = []
    for item in input.arrivals {
        guard let envelope = try? Phi_PhiEntity(serializedBytes: item.payload),
              let entity = PinKind.entity(from: envelope) else { continue }
        arrivals.append(OwnedItemArrival(entity: entity, entityId: item.entityId,
                                         version: item.version))
        out.serverBytes[PinKind.identity(of: entity)] = item.payload
    }
    var context = OwnedItemPlanContext()
    context.tombstonedIdentities = input.tombstoned
    context.localProjections = pinLocalProjections(
        for: Set(arrivals.map { PinKind.identity(of: $0.entity) }).union(input.parked.keys),
        table: input.table, resolve: input.maps.resolver, now: input.now, state: state)
    // Pass scope mismatch to the pure planner, yielding no steps and parking all arrivals (section
    // 7.3). Pins are flat, so liveLocalParents and deletedSubtree stay empty and those A9
    // conditions are vacuous.
    context.localScope = state.localScope
    context.accountScope = state.accountScope
    context.scopeMovedMidRound = state.scopeMovedMidRound
    out.plan = SyncableOwnedItems.plan(PinKind.self, arrivals: arrivals, parked: input.parked,
                                       table: input.table, resolve: input.maps.resolver,
                                       context: context)
    // Report whether section 7.3 suppressed pin publication this round (section 11.2).
    out.scopeMismatch = context.scopeMismatch
    // Locally winning fields still require republication (section 6.2). Pins skip adoption, not the
    // merge rule itself.
    out.mustRepublish = out.plan.mustRepublish
    return out
}

/// Pin counterpart to bookmarkLocalProjections: pins are flat, need no parent resolution, derive
/// identities and retain the first row for duplicate identities as landPins does. Rank likewise
/// comes from the baseline.
@MainActor
private func pinLocalProjections(for identities: Set<String>,
                                 table: PhiOwnedItemTable,
                                 resolve: OwnerResolver,
                                 now: Int64,
                                 state: PinSyncRoundState) -> [String: Data] {
    guard !identities.isEmpty else { return [:] }
    var rowOf: [String: PhiLocalPin] = [:]
    for row in state.locals {
        guard let identity = PinKind.identity(of: row, resolve: resolve, scope: state.localScope),
              identities.contains(identity), rowOf[identity] == nil else { continue }
        rowOf[identity] = row
    }
    var out: [String: Data] = [:]
    for (identity, row) in rowOf {
        guard let baselineBytes = table.cursors[identity]?.reconciled,
              let baselineEnvelope = try? Phi_PhiEntity(serializedBytes: baselineBytes),
              let baseline = PinKind.entity(from: baselineEnvelope),
              let projected = PinKind.project(row, resolve: resolve, scope: state.localScope,
                                              parentIdentity: nil) else { continue }
        let stamped = PinKind.stamp(projected, baseline: baseline, local: row,
                                    rank: PinKind.rank(of: baseline), now: now)
        guard let bytes = try? PinKind.envelope(stamped).serializedData() else { continue }
        out[identity] = bytes
    }
    return out
}

/// Pin landing in one transaction: variant normalization, three-phase batch, then post-check
/// (sections 4.4/4.5). Pins are flat and owner-grouped, so no lifting or per-Space split is needed;
/// non-create operations identify rows by GUID and the store derives their ownership.
@MainActor
private func landPins(_ input: OwnedLandingInput,
                      access: any PhiPinnedTabLocalAccess,
                      state: PinSyncRoundState) async -> OwnedLandingOutcome {
    var outcome = OwnedLandingOutcome()
    let resolve = input.maps.resolver
    let scope = state.localScope

    // Resample immediately before landing (R-exec-12). Scope migration may have replaced the
    // physical rows behind the cached identities/GUIDs, so both creates and A11 reminting would be
    // unsafe. Park all input instead. pendingApply retains consumed payloads; next round's
    // consistent projection can update existing migrated rows without duplication.
    state.rescanScopes(localScope: access.currentScope(), accountScope: access.accountScope())
    guard !state.scopeBlocked else {
        for step in input.steps { outcome.parked.insert(step.identity) }
        return outcome
    }

    // Normalize same-owner lineage variants (section 7.2 / A11): collapse exact signature
    // duplicates, then remint remaining variants except the lowest-index row. This is a local write
    // in the same PinApplyBatch transaction as landing, never the read-only publication pre-pass
    // (W14).
    var ops = PinKind.normalizeVariants(locals: state.locals).ops
    // Count reminting only after the batch commits; refused/parked transactions changed no rows.
    // Count relineage operations, not all ops, since A11 also emits duplicate-removal deletes.
    var relineaged = 0
    var collapsedDuplicates = 0
    for op in ops {
        switch op {
        case .relineage: relineaged += 1
        case .delete: collapsedDuplicates += 1
        default: break
        }
    }
    guard !input.steps.isEmpty || !ops.isEmpty else { return outcome }

    // Keep the first row per derived identity, matching snapshot deduplication and A11 collapse.
    // allPins sorts by ownerKey/index/GUID, so all three select the same survivor. Last-wins
    // indexing could apply an incoming update to the duplicate deleted later in the transaction,
    // losing the edit.
    var rowOf: [String: PhiLocalPin] = [:]
    for row in state.locals {
        guard let identity = PinKind.identity(of: row, resolve: resolve, scope: scope) else {
            continue
        }
        if rowOf[identity] == nil { rowOf[identity] = row }
    }

    /// Resolve account ownerKey into local Space/Profile fields, reversing the section 7.2 mapping.
    func localOwner(_ ownerKey: String) -> (spaceId: String?, profileId: String?)? {
        // Require the owner's shape to match the current local scope: app, Space and Profile each
        // resolve only in their matching scope (section 7.2). Otherwise an old-shape account entity
        // can fall through defaultSpaceId/current-owner normalization, duplicate a migrated row,
        // and fail post-check on every replay. Park mismatches rather than refuse them; they can
        // heal as account scope converges.
        if ownerKey == OwnedOwnerMaps.appOwnerKey {
            guard scope == .app else { return nil }
            return (nil, nil)
        }
        if let spaceId = resolve.localSpaceId(ownerKey) {
            guard scope == .space else { return nil }
            // A Space-scoped pin has both fields: the Space's own Profile first (review A5) —
            // Space-scope queries match on both ids, so a pin created under any other Profile is
            // invisible to that Space's windows — then another row's Profile in that Space, then
            // the default Profile, matching bookmark landing's fallback order.
            let profileId = resolve.localProfileIdForSpace(spaceId)
                ?? state.locals.first { $0.spaceId == spaceId }?.profileId
                ?? LocalStore.defaultProfileId
            return (spaceId, profileId)
        }
        if let profileId = resolve.localProfileId(ownerKey) {
            guard scope == .profile else { return nil }
            return (nil, profileId)
        }
        return nil
    }

    struct Planned {
        var step: OwnedItemApplyStep
        var entity: Phi_PhiPinTabEntity?
        var identity: String
        var ownerKey: String
    }
    var planned: [Planned] = []
    for step in input.steps {
        // Pins do not adopt, so claim is structurally unreachable. Skip rather than invent
        // semantics (section 6.7).
        guard step.kind != .claim else { continue }
        let entity = step.payload.flatMap { bytes -> Phi_PhiPinTabEntity? in
            guard let envelope = try? Phi_PhiEntity(serializedBytes: bytes) else { return nil }
            return PinKind.entity(from: envelope)
        }
        planned.append(Planned(step: step, entity: entity, identity: step.identity,
                               ownerKey: pinIdentityHalves(step.identity).ownerKey))
    }

    // Round landing projection includes initial rows and newly created rows. It answers identity
    // existence and owner membership for rank projection and split-partner resolution.
    var projected: [String: PhiLocalPin] = state.rowByGuid
    var guidOf: [String: String] = [:]
    for (identity, row) in rowOf { guidOf[identity] = row.guid }
    var rankOf: [String: String] = [:]
    for (identity, cursor) in input.table.cursors {
        guard let bytes = cursor.reconciled,
              let envelope = try? Phi_PhiEntity(serializedBytes: bytes),
              let entity = PinKind.entity(from: envelope) else { continue }
        rankOf[identity] = PinKind.rank(of: entity)
    }

    var created: Set<String> = []
    var deletedIdentities: Set<String> = []
    var payloadOf: [String: Data] = [:]
    var touchedOwners: Set<String> = []
    var ownerOfGuid: [String: String] = [:]
    for (identity, row) in rowOf {
        ownerOfGuid[row.guid] = PinKind.eligibilityOwner(of: row, resolve: resolve, scope: scope)
            ?? pinIdentityHalves(identity).ownerKey
    }

    for item in planned {
        let identity = item.identity
        if let payload = item.step.payload { payloadOf[identity] = payload }
        if let rank = item.step.newRank { rankOf[identity] = rank }
        // Content-only updates do not touch owner ordering. Rank changes already produce a separate
        // move step; adding every update's owner here would emit unrelated full sibling
        // permutations for renames or split links. Bookmark landing follows the same principle.
        if item.step.kind != .update { touchedOwners.insert(item.ownerKey) }

        if item.step.kind == .delete {
            deletedIdentities.insert(identity)
            guard let guid = guidOf[identity] else { continue }
            projected.removeValue(forKey: guid)
            continue
        }
        guard let entity = item.entity else { continue }
        if guidOf[identity] == nil {
            // Park unresolved local owner shapes until Space/Profile mappings become available.
            guard let owner = localOwner(item.ownerKey) else {
                outcome.parked.insert(identity)
                continue
            }
            // Enforce one row per lineage/owner at the actual local landing boundary (section 7).
            // guidOf derives account identities through forward mappings, which may be missing or
            // describe an old owner shape after scope migration. Recheck lineage under the resolved
            // local owner before create to avoid duplicating an existing migrated row. Park rather
            // than refuse: delayed mappings can heal next round and turn this into an update.
            let landingLineage = PinKind.lineageKey(pinIdentityHalves(identity).lineage)
            let landingOwnerKey = owner.spaceId ?? owner.profileId ?? OwnedOwnerMaps.appOwnerKey
            let ownerAlreadyHasLineage = projected.values.contains { row in
                PinKind.lineageKey(row.lineageId) == landingLineage
                    && (row.spaceId ?? row.profileId ?? OwnedOwnerMaps.appOwnerKey)
                        == landingOwnerKey
            }
            guard !ownerAlreadyHasLineage else {
                outcome.parked.insert(identity)
                continue
            }
            let guid = UUID().uuidString
            guidOf[identity] = guid
            created.insert(identity)
            ownerOfGuid[guid] = item.ownerKey
            projected[guid] = PhiLocalPin(
                lineageId: pinIdentityHalves(identity).lineage,
                guid: guid, spaceId: owner.spaceId, profileId: owner.profileId,
                index: 0, title: entity.title.stringValue,
                url: URL(string: entity.url.stringValue)
                    ?? URL(string: "https://pin.phi/placeholder")!,
                splitPartnerLineageId: nil, source: Int(entity.source),
                createdDate: Date(timeIntervalSince1970: Double(entity.createdAtMs) / 1000),
                // Persist the incoming content timestamp, not nil or landing time (R-exec-5). Nil
                // would fall back to the newly created row's date and falsely beat later remote
                // edits. Use max(title stamp, URL stamp), since the no-baseline PinKind stamping
                // path applies this shared time to both content fields (section 4.2(5)).
                contentUpdatedDate: Date(timeIntervalSince1970:
                                            Double(max(entity.title.updatedAtMs,
                                                       entity.url.updatedAtMs)) / 1000),
                isDormant: false)
        }
    }

    // Project ranks to indices per owner, since pins are flat (section 4.10). Emit a full dense
    // permutation for every touched owner; raw index writes do not shift siblings (M7). Prefer
    // planned ranks, otherwise baseline ranks.
    var rankByGuid: [String: String] = [:]
    for (identity, guid) in guidOf {
        guard let rank = rankOf[identity] else { continue }
        rankByGuid[guid] = rank
    }
    var indexOf: [String: Int] = [:]
    for owner in touchedOwners {
        let members = projected.values
            .filter { ownerOfGuid[$0.guid] == owner }
            .sorted { lhs, rhs in
                switch (rankByGuid[lhs.guid], rankByGuid[rhs.guid]) {
                case let (left?, right?):
                    // Break rank ties by normalized pin_uuid/lineage, never device-local GUID
                    // (section 2.4). GUID ordering differs across devices and can cause endless
                    // opposing reorder commits; lineage is shared.
                    return left == right
                        ? PinKind.lineageKey(lhs.lineageId) < PinKind.lineageKey(rhs.lineageId)
                        : left < right
                // Place rankless, untouched and never-published local rows last to avoid reordering
                // unrelated rows on every landing.
                case (nil, _?): return false
                case (_?, nil): return true
                case (nil, nil):
                    return lhs.index == rhs.index ? lhs.guid < rhs.guid : lhs.index < rhs.index
                }
            }
        for (position, row) in members.enumerated() { indexOf[row.guid] = position }
    }

    // Phase 1: create, relineage and move.
    var indexed: Set<String> = []
    // Track genuinely new pins for favicon backfill after successful landing checks (section 8.2 /
    // Task 10).
    var createdPinsByIdentity: [String: PhiLocalPin] = [:]
    for item in planned where item.step.kind != .delete {
        guard let guid = guidOf[item.identity], !outcome.parked.contains(item.identity) else {
            continue
        }
        if created.contains(item.identity), var row = projected[guid] {
            // Emit at most one create per identity even when plan supplies both move and update.
            // created/guidOf are identity-keyed, while this loop visits steps; emitting twice would
            // create duplicate physical rows sharing a GUID. A11 cannot safely repair shared GUIDs,
            // and sidebar dictionaries can trap on the duplicate key.
            guard createdPinsByIdentity[item.identity] == nil else { continue }
            row.index = indexOf[guid] ?? 0
            projected[guid] = row
            ops.append(.create(row))
            createdPinsByIdentity[item.identity] = row
            indexed.insert(guid)
        } else if item.step.kind == .create || item.step.kind == .move {
            // Resolve identity before create (section 4.5). An already existing local pin makes a
            // planned create a replay/update, not a second physical row.
            ops.append(.move(guid: guid, index: indexOf[guid] ?? 0))
            indexed.insert(guid)
        }
    }
    // Assign final indices to remaining existing rows under touched owners.
    for owner in touchedOwners {
        let movers = projected.values
            .filter { ownerOfGuid[$0.guid] == owner && !indexed.contains($0.guid)
                && state.rowByGuid[$0.guid] != nil }
            .sorted { (indexOf[$0.guid] ?? 0, $0.guid) < (indexOf[$1.guid] ?? 0, $1.guid) }
        for row in movers {
            ops.append(.move(guid: row.guid, index: indexOf[row.guid] ?? row.index))
        }
    }

    // Phase 2: content patches and split-partner resolution (section 7.4). If a same-owner partner
    // exists, write both directions transactionally. Otherwise leave the local link untouched and
    // persist pendingPartnerLineage so the next snapshot does not publish an empty link that breaks
    // the peer's intact split.
    var reverseLinks: [PinApplyOp] = []
    var linkedPartners: [String: String] = [:]
    var clearedPartners: Set<String> = []
    for item in planned where item.step.kind != .delete {
        guard let entity = item.entity, let guid = guidOf[item.identity],
              !outcome.parked.contains(item.identity) else { continue }
        var fields = PinFieldPatch()
        if !created.contains(item.identity) {
            fields.title = .some(entity.title.stringValue)
            fields.url = .some(URL(string: entity.url.stringValue))
        }
        let partner = PinKind.lineageKey(entity.splitPartnerUuid.stringValue)
        if partner.isEmpty {
            // A remote unlink clears the local link and pending wait. If the row is already
            // unlinked, avoid a redundant patch and updatedDate write.
            if state.rowByGuid[guid]?.splitPartnerLineageId != nil {
                fields.splitPartnerLineageId = .some(nil)
                clearedPartners.insert(guid)
            }
            outcome.pendingPartnerLineages[item.identity] = ""
        } else {
            let partnerRow = projected.values.first {
                $0.guid != guid && ownerOfGuid[$0.guid] == item.ownerKey
                    && PinKind.lineageKey($0.lineageId) == partner
            }
            fields.splitPartnerLineageId = .some(partner)
            linkedPartners[guid] = partner
            // Record the missing partner lineage for a partially landed pair; empty means no longer
            // waiting.
            outcome.pendingPartnerLineages[item.identity] = partnerRow == nil ? partner : ""
            // Repair the reverse link in the same transaction (section 7.4). The partner may have
            // arrived in an earlier round and still be waiting; updating only this arrival would
            // leave peer displays inconsistent until another local change.
            let thisLineage = PinKind.lineageKey(pinIdentityHalves(item.identity).lineage)
            if let partnerRow {
                let partnerIdentity = PinKind.lineageKey(partnerRow.lineageId) + ":"
                    + item.ownerKey
                if input.table.cursors[partnerIdentity]?.pendingPartnerLineage == thisLineage,
                   PinKind.lineageKey(partnerRow.splitPartnerLineageId ?? "") != thisLineage {
                    reverseLinks.append(.update(
                        guid: partnerRow.guid,
                        fields: PinFieldPatch(splitPartnerLineageId: .some(thisLineage))))
                    linkedPartners[partnerRow.guid] = thisLineage
                    outcome.pendingPartnerLineages[partnerIdentity] = ""
                }
            }
        }
        guard fields.title != nil || fields.url != nil || fields.splitPartnerLineageId != nil
        else { continue }
        ops.append(.update(guid: guid, fields: fields))
    }
    // Append reverse-link patches in phase 2 after patches for the arriving side.
    ops.append(contentsOf: reverseLinks)

    // Phase 3: deletion.
    for item in planned where item.step.kind == .delete {
        // Section 5.6 T3: a known identity without a local row needs no physical deletion, but
        // still finalizes deletedAtMs.
        guard let guid = guidOf[item.identity], state.rowByGuid[guid] != nil else {
            outcome.landed.insert(item.identity)
            outcome.deleted.insert(item.identity)
            continue
        }
        ops.append(.delete(guid: guid))
    }

    guard !ops.isEmpty else { return outcome }
    let identities = Set(planned.map(\.identity))
        .subtracting(outcome.parked)
        .subtracting(outcome.landed)
    do {
        try await access.apply(PinApplyBatch(unordered: ops))
    } catch LocalStoreWriteError.rowAlreadyMapped, LocalStoreWriteError.rowNotFound,
            LocalStoreWriteError.rowNotInActiveScope, LocalStoreWriteError.noCandidateSurvived {
        // Refuse an invalid batch rather than parking it for endless identical retries.
        outcome.refused.formUnion(identities)
        // No operation committed, so no partner-state updates can be acknowledged; return an empty
        // map as for parking.
        outcome.pendingPartnerLineages = [:]
        return outcome
    } catch {
        // Park import-lock and other transient failures for retry next round.
        outcome.parked.formUnion(identities)
        outcome.pendingPartnerLineages = [:]
        return outcome
    }
    // Only a committed transaction can report reminting.
    outcome.relineaged = relineaged
    // Exact duplicates have no distinct account identities, so their local removal is invisible to
    // cursor/diff counters. Emit one metadata-only warning with kind/count (R12) to make future
    // races diagnosable.
    if collapsedDuplicates > 0 {
        AppLogWarn("[phi-sync] pins: collapsed \(collapsedDuplicates) exact duplicate row(s) "
                   + "sharing an identity; a round landed beside rows it could not see")
    }
    // Reflect transactionally written split links in the round projection immediately, preventing
    // publication from misreading a newly received link as a local unlink (section 7.4).
    state.noteSplitPartnerWrites(linked: linkedPartners, cleared: clearedPartners)

    // Recheck post-landing rows before baseline write-back (section 4.5). apply rebuilds its cache,
    // so this observes committed state.
    for identity in identities {
        let halves = pinIdentityHalves(identity)
        // Check full identity, not lineage (R-M3-3-15). isKnownLocalPin requires a local owner key,
        // so reverse-resolve the account UUID through localOwner first. An unresolvable local shape
        // cannot have a matching row.
        let localOwnerKey = localOwner(halves.ownerKey)
            .map { $0.spaceId ?? $0.profileId ?? OwnedOwnerMaps.appOwnerKey }
        let known = access.isKnownLocalPin(halves.lineage, ownerKey: localOwnerKey)
        if deletedIdentities.contains(identity) {
            // Lineage alone could indefinitely park a deletion because a different owner's variant
            // still exists. Exact-identity presence means this specific owner's row really remains,
            // making parking appropriate.
            if known { outcome.parked.insert(identity) } else {
                outcome.landed.insert(identity)
                outcome.deleted.insert(identity)
            }
            continue
        }
        guard known else { outcome.parked.insert(identity); continue }
        outcome.landed.insert(identity)
        // New pins lack favicons by construction; submit them for backfill (section 8.2 / Task 10).
        if let created = createdPinsByIdentity[identity] { outcome.createdPins.append(created) }
        if let payload = payloadOf[identity] { outcome.reconciled[identity] = payload }
    }
    outcome.parked.subtract(outcome.landed)
    outcome.refused.subtract(outcome.landed)
    // Remove actually deleted rows from the round projection immediately, as for bookmarks (CASE
    // 6b.8).
    state.noteDeletedRows(Set(outcome.deleted.compactMap { guidOf[$0] }))
    // After committed pin landing, refresh the projection from access's post-apply cache (Step 3).
    // Otherwise stale title/order values would be stamped with a new now and sent back over the
    // remote edit.
    if let refreshed = access.cachedPins() { state.refreshLandedRows(refreshed) }
    return outcome
}

// MARK: - URL Rule（M3-4a Task 6）

/// URL-rule round projection is refreshed per page, not frozen at round start (R-M3-4a-62).
/// beginRound reads the first page's state; landURLRules refreshes after each committed landing
/// batch.
@MainActor
final class URLRuleSyncRoundState {
    /// All rows from this page's read, including soft-deleted rows needed by deletion diff (section
    /// 5.7).
    private(set) var rows: [PhiLocalURLRule] = []
    /// Rows with deletedDate nil: the outbound snapshot and dense-reorder domain (R-M3-4a-51).
    private(set) var live: [PhiLocalURLRule] = []
    /// The latest page reload failed after committing its batch. Retain the previous projection;
    /// never interpret the failure as zero rows, matching R-exec-3.
    private(set) var pageReloadFailed = false
    /// Shared row-side comparison baseline for section 8.4.5(a)/(b) (ruling 2 / R-M3-4a-91).
    /// Capture all three merge units at the same time snapshot emits each identity's bytes. This
    /// represents the submitted payload while retaining Date submillisecond precision; comparing
    /// decoded Int64-millisecond payload stamps directly with rows would never match. Clear at
    /// every publication snapshot entry.
    var publishBaseline: [String: RuleProjection] = [:]
    /// Resolver captured with publishBaseline for pendingLocalEditIdentities filtering in hook (b).
    /// Its Set<String>-only callback cannot receive maps directly (R-M3-4a-96). Nil skips clearing
    /// fail-closed.
    private(set) var publishResolver: OwnerResolver?

    /// At publication snapshot start, replace the resolver and discard the previous baseline.
    func beginPublishBaseline(resolve: OwnerResolver) {
        publishBaseline = [:]
        publishResolver = resolve
    }

    /// Current row spaceId by identity for URLRuleApplyBatch. Prefer the sole live row; a
    /// soft-deleted row represents the identity only if no live row exists.
    var currentSpaceIds: [String: String] {
        var out: [String: String] = [:]
        for row in live {
            guard let identity = row.syncId, out[identity] == nil else { continue }
            out[identity] = row.spaceId
        }
        for row in rows {
            guard let identity = row.syncId, out[identity] == nil else { continue }
            out[identity] = row.spaceId
        }
        return out
    }

    func reload(_ rows: [PhiLocalURLRule]) {
        self.rows = rows
        live = rows.filter { $0.deletedDate == nil }
        pageReloadFailed = false
    }

    /// Refresh after each committed page (R-M3-4a-62). apply already rebuilt access's page cache;
    /// adopt those same rows. landURLRules first reflects persisted claims/deletions after apply,
    /// then uses this reload as a fallback (8b-1).
    func reloadAfterPage(_ access: any PhiURLRuleLocalAccess) {
        guard let rows = try? access.allURLRulesIncludingDeleted() else {
            pageReloadFailed = true
            return
        }
        reload(rows)
    }
}

extension OwnedKindRegistration {
    /// URLRuleKind registration (section 6.1), following bookmark/pin registration structure.
    @MainActor
    static func urlRules(access: any PhiURLRuleLocalAccess,
                         store: any PhiOwnedItemStateStore) -> OwnedKindRegistration {
        let state = URLRuleSyncRoundState()
        return OwnedKindRegistration(
            label: "urlrules",
            tagPrefix: PhiSyncEntity.urlRuleTagPrefix,
            entityName: PhiSyncEntity.urlRuleEntityName,
            store: store,
            flags: .urlRules,
            // Rules do not use bookmark adoption or pin scopes. M1 claims rekey during section
            // 8.4.2 landing.
            reportsAdoption: false,
            reportsScope: false,
            reportsRuleCounters: true,
            // Rules yield tombstones, enabling the engine's round-end rule-3b admission recheck
            // (sections 6.1/8.4.4, ruling 7).
            tombstoneYieldsToLocalEdits: URLRuleKind.tombstoneYieldsToLocalEdits,
            // Rules run plan/land even when arrivals, tombstones and parked sets are all empty
            // (R-M3-4a-99/56).
            landsEmptyBatch: true,
            identity: { envelope in
                guard let entity = URLRuleKind.entity(from: envelope) else { return nil }
                let identity = URLRuleKind.identity(of: entity)
                return identity.isEmpty ? nil : identity
            },
            clientTag: PhiSyncEntity.urlRuleClientTag,
            owners: { bytes in
                guard let envelope = try? Phi_PhiEntity(serializedBytes: bytes),
                      let entity = URLRuleKind.entity(from: envelope) else { return [] }
                return URLRuleKind.ownerUuids(of: entity)
            },
            // Rules have no split partners; nil skips section 7.4 doctoring and its actor hop, as
            // for bookmarks.
            clearedSplitPartners: nil,
            // This initializes only the first page's projection, not a frozen round snapshot
            // (R-M3-4a-62). Read failure follows R-exec-3.
            beginRound: { state.reload(try access.allURLRulesIncludingDeleted()) },
            // Seed tags from every local syncId, including soft-deleted rows whose remote
            // tombstones must route (section 5.1 / R-M3-4a-23). Reuse rows just loaded by
            // beginRound without a second fetch; this callback is not called when that read throws.
            localIdentities: { Set(state.rows.compactMap(\.syncId)) },
            snapshot: { table, maps, now, hlcMax in
                urlRuleSnapshot(table: table, maps: maps, now: now, hlcMax: hlcMax, state: state)
            },
            tombstones: { table, maps, now in
                // Use the single round-end read including soft-deleted rows (R-M3-4a-51). Let
                // failure propagate so publication fails closed, increments local_read_failed and
                // writes no cursor bytes. Never substitute an empty collection.
                let rows = try access.allURLRulesIncludingDeleted()
                // Derive three sets from one read, without extra storage access.
                var locals: [PhiLocalURLRule] = []
                var explicitDeletions: Set<String> = []
                for row in rows {
                    guard let syncId = row.syncId else { continue }
                    if row.deletedDate == nil {
                        // Do not filter this deletion domain by ownership (R-M3-4a-51).
                        // Hidden/purged targets, agent rules and obsolete incognito bindings still
                        // contribute their syncId as live identities, preventing false absence.
                        // Snapshot owns eligibility filtering (R-M3-4a-5/8).
                        locals.append(row)
                    } else if table.cursors[syncId]?.reconciled != nil {
                        // Deletion origin (b): soft-deleted row with an identity and an actual
                        // account baseline (R-M3-4a-78).
                        explicitDeletions.insert(syncId)
                    }
                }
                // Section 8.4.4(beta) guard requires both a non-at-rest partner and pending
                // incoming apply, evaluated from this same read (R-M3-4a-84 / ruling 5). Omitting
                // the cause check would indefinitely block legitimate owner-shape-parked user
                // deletions; omitting pendingApply would block ordinary M2 losers. Include
                // soft-deleted rows because X is necessarily soft-deleted here. Publication runs
                // outside pagination, so tombstonesThisPage is empty.
                let notAtRest = access.partnerNotAtRest(table: table, rows: rows,
                                                        resolve: maps.resolver,
                                                        tombstonesThisPage: [])
                let deferredDeletions = notAtRest.filter { table.cursors[$0]?.pendingApply != nil }
                return SyncableOwnedItems.tombstones(
                    URLRuleKind.self, locals: locals,
                    table: table, resolve: maps.resolver, scope: nil, nowMs: now,
                    // Rules have no pending identity write-back claims (section 5.1).
                    pendingClaims: [],
                    explicitDeletions: explicitDeletions,
                    deferredDeletions: deferredDeletions)
            },
            // Rule claims rekey inside the landing transaction, so no matched-but-unpersisted state
            // exists (section 6.1 / R-M3-4a-53). Keep an explicit no-op callback for generic retry
            // wiring (R-exec-10).
            retryParkedClaims: { _, _ in OwnedParkedClaimResult() },
            plan: { input in urlRulePlan(input, access: access, state: state) },
            land: { input in await landURLRules(input, access: access, state: state) },
            // Rule identities are minted at LocalStore insertion; publication has no identity
            // write-back window (R-M3-4a-53).
            claimIdentities: { _ in [] },
            // For applied live publications, compare each captured baseline before clearing
            // pendingLocalEdit (section 8.4.5(a)). Missing baselines fail closed: only actual
            // snapshot entries were published this round.
            notePublishApplied: { identities in
                for identity in identities.sorted() {
                    guard let baseline = state.publishBaseline[identity] else { continue }
                    do {
                        _ = try await access.clearPendingLocalEdit(syncId: identity,
                                                                   ifProjectionEquals: baseline)
                    } catch {
                        // Log kind and sanitized error type only, never identity/host/path_prefix
                        // (R12). Failure does not block other writes; hook (b) recomputes recovery
                        // next round (section 8.4.5).
                        AppLogWarn("[phi-sync] clearing a rule pending-local-edit flag failed "
                                   + "kind=urlrules (\(PhiSyncLog.describe(error)))")
                    }
                }
            },
            // Second layer of section 8.4.5(b) (R-M3-4a-96). Generic publication supplies IDs; this
            // factory closure owns state and baselines. Resolve captured publishBaseline entries,
            // dropping missing values; filter through the same pendingLocalEditIdentities function
            // as plan; return without a transaction for an empty set (CASE M-19x(x3)); otherwise
            // call clearPendingLocalEditIfUnchanged. The primitive performs the final projection
            // comparison inside its transaction (RR12-7), reusing hook (a)'s baseline channel.
            clearPendingLocalEdits: { candidates in
                guard !candidates.isEmpty, let resolve = state.publishResolver else { return }
                var entries: [String: RuleProjection] = [:]
                for identity in candidates {
                    guard let baseline = state.publishBaseline[identity] else { continue }
                    entries[identity] = baseline
                }
                let flagged = access.pendingLocalEditIdentities(resolve: resolve)
                entries = entries.filter { flagged.contains($0.key) }
                guard !entries.isEmpty else { return }
                do {
                    try await access.clearPendingLocalEditIfUnchanged(entries: entries)
                } catch {
                    // R12 metadata only. Recompute next round; no cross-store atomic transaction is
                    // needed.
                    AppLogWarn("[phi-sync] the rule pending-local-edit self-heal failed "
                               + "kind=urlrules (\(PhiSyncLog.describe(error)))")
                }
            },
            liveOwners: { candidates, maps in
                // access.liveOwners supplies claimed identities for condition (b). Resolve current
                // owners with the same eligibilityOwner as snapshot (A12). A live row with
                // unresolved ownership still protects its cursor; omit its owner so no guessed
                // rehome is written (R-M3-4a-36).
                var out = try access.liveOwners(candidates)
                let resolve = maps.resolver
                for row in state.live {
                    guard let identity = row.syncId, out.claimed.contains(identity),
                          let owner = URLRuleKind.eligibilityOwner(of: row, resolve: resolve,
                                                                   scope: nil)
                    else { continue }
                    out.owners[identity] = owner
                }
                return out
            },
            hardDeleteAfterTombstone: { identities in
                for syncId in identities.sorted() {
                    do { try await access.hardDeleteURLRule(syncId: syncId) } catch {
                        AppLogWarn("[phi-sync] hard-deleting a soft-deleted rule failed kind=urlrules "
                                   + "(\(PhiSyncLog.describe(error)))")
                    }
                }
            },
            purgeSoftDeletedRows: { cutoff in
                do { return try await access.purgeSoftDeletedURLRules(olderThan: cutoff) } catch {
                    AppLogWarn("[phi-sync] the soft-deleted rule sweep failed kind=urlrules "
                               + "(\(PhiSyncLog.describe(error)))")
                    return 0
                }
            })
    }
}

/// URL-rule outbound snapshot (section 4.2). minted stays empty because insertion already assigned
/// identity (R-M3-4a-23); scopeMismatch stays false because rules have no scope.
@MainActor
private func urlRuleSnapshot(table: PhiOwnedItemTable, maps: OwnedOwnerMaps, now: Int64,
                             hlcMax: Int64,
                             state: URLRuleSyncRoundState) -> OwnedSnapshotBytes {
    var out = OwnedSnapshotBytes()
    let resolve = maps.resolver
    // Capture fresh comparison baselines for both section 8.4.5 clearing paths on every publication
    // pass (ruling 2).
    state.beginPublishBaseline(resolve: resolve)
    var rowsByIdentity: [String: PhiLocalURLRule] = [:]
    for row in state.live {
        guard let identity = row.syncId, rowsByIdentity[identity] == nil else { continue }
        rowsByIdentity[identity] = row
    }
    let result = SyncableOwnedItems.snapshot(URLRuleKind.self, locals: state.live, table: table,
                                             resolve: resolve, scope: nil, now: now,
                                             hlcMax: hlcMax)
    out.skippedUnmappedOwner = result.skippedUnmappedOwner
    out.skippedIneligibleOwner = result.skippedIneligibleOwner
    for (identity, entity) in result.entities {
        guard let bytes = try? URLRuleKind.envelope(entity).serializedData() else { continue }
        out.entities[identity] = bytes
        // Capture the row's three merge units together with its snapshot bytes (ruling 2). Failed
        // serialization enters neither snapshot nor baseline, so both clearing hooks fail closed.
        if let row = rowsByIdentity[identity] {
            state.publishBaseline[identity] = URLRuleKind.clearingProjection(of: row)
        }
    }
    // Refresh identity-to-current-owner values using the same eligibilityOwner as the liveOwners
    // callback (A12 / section 3.5).
    for row in state.live {
        guard let identity = row.syncId,
              let owner = URLRuleKind.eligibilityOwner(of: row, resolve: resolve, scope: nil)
        else { continue }
        out.ownerUuids[identity] = owner
    }
    return out
}

/// Incoming rule plan: decode, preserve server bytes, normalize (section 8.1), run M1 adoption
/// pre-pass (section 8.4.2), project local rows, then invoke the pure planner.
@MainActor
private func urlRulePlan(_ input: OwnedPlanInput, access: any PhiURLRuleLocalAccess,
                         state: URLRuleSyncRoundState) -> OwnedPlanOutput {
    var out = OwnedPlanOutput()
    var arrivals: [OwnedItemArrival<Phi_PhiURLRuleEntity>] = []
    for item in input.arrivals {
        guard let envelope = try? Phi_PhiEntity(serializedBytes: item.payload),
              let entity = URLRuleKind.entity(from: envelope) else { continue }
        arrivals.append(OwnedItemArrival(entity: entity, entityId: item.entityId,
                                         version: item.version))
        // Preserve raw pre-normalization bytes as server (ruling 5). Storing normalized bytes would
        // falsely claim account equality, suppress needed republication and leave normalized counts
        // oscillating between peers.
        out.serverBytes[URLRuleKind.identity(of: entity)] = item.payload
        // Best-effort deferred owners use the incoming entity's target, matching ownerUuids
        // (section 5.3).
        let target = entity.targetSpaceUuid.stringValue
        if !target.isEmpty { out.deferredOwners.insert(target) }
    }
    // Normalize arrivals in place (section 8.1 / R-M3-4a-29). Changed bytes require republication,
    // which the pure planner cannot infer alone.
    let normalized = URLRuleKind.normalizeArrivals(arrivals) {
        LocalStore.normalizedRule(host: $0, pathPrefix: $1)
    }
    arrivals = normalized.arrivals
    out.normalized = normalized.normalized.count
    var context = OwnedItemPlanContext()
    context.tombstonedIdentities = input.tombstoned
    // §8.4.2 M1: run the claim pre-pass immediately after normalization so signatures use
    // normalized values. `ownedItemsPublishAllowed` does not gate this pass: plan ruling 4 gates
    // only §8.4.3 step 2, while M1 must run during drain (CASE M-11). Populate the three context
    // members introduced in M3-3.
    let claims = urlRuleClaims(arrivals: arrivals, parked: input.parked, table: input.table,
                               resolve: input.maps.resolver, now: input.now,
                               access: access, state: state)
    context.pairs = claims.pairs
    context.adoptedMerges = claims.merges
    context.adoptedFieldWrites = claims.fieldWrites
    out.claimedLocalIds = claims.pairs
    out.retiredIdentities = claims.retired
    out.adopted = claims.pairs.count
    // The domain is arrivals ∪ parked identities ∪ this page's tombstones (§5.6 final paragraph /
    // §11). The last set supplies `context.localProjections[X]` for §8.4.4 (α) transfers. Bookmark
    // behavior stays unchanged: section 6 never reads these projections.
    context.localProjections = urlRuleLocalProjections(
        for: Set(arrivals.map { URLRuleKind.identity(of: $0.entity) })
            .union(input.parked.keys).union(input.tombstoned),
        table: input.table, resolve: input.maps.resolver, now: input.now, state: state)
    // The four named §8.4.4 inputs (R-M3-4a-73, 8b-3) share the signature index's pre-pass, cursor
    // table, and rows (`state.rows` from this page's `allURLRulesIncludingDeleted()`). Keep the
    // predicates in the kind: signatures and soft deletion are rule-specific, and
    // `OwnedItemPlanContext` cannot carry row-level booleans.
    context.pendingLocalEdits = access.pendingLocalEditIdentities(resolve: input.maps.resolver)
    context.unpublished = access.unpublishedIdentities(table: input.table,
                                                       resolve: input.maps.resolver)
    context.mergePartners = access.mergePartners(table: input.table, resolve: input.maps.resolver,
                                                 tombstonesThisPage: input.tombstoned)
    context.partnerNotAtRest = access.partnerNotAtRest(table: input.table, rows: state.rows,
                                                       resolve: input.maps.resolver,
                                                       tombstonesThisPage: input.tombstoned)
    // D30 M2's two pre-pass inputs (8b-2 rulings 2 / 6) must be computed before
    // `SyncableOwnedItems.plan`, using this page's `state.live` projection and current cursor
    // table. `beginRound` / `reloadAfterPage` refresh the projection per page (R-M3-4a-62).
    // `localSignatures` is copied by identity into `OwnedItemPlan.preLandingSignatures` when
    // planning `.move` / `.update`; it supplies the second pointer pass's grouping key. Recompute
    // each page so page N+1 sees page N's landed rows (CASE M2-b).
    // `atRestIdentities` applies all ten predicates. Predicate 10 reads this page's `tombstoned`
    // set, which the tail hook cannot access; never move that computation into the hook (CASE
    // M-27).
    let resolve = input.maps.resolver
    let normalize = URLRuleSignatureQueries.normalize
    // Build a third table in the same pass: current signature -> live identities in that group. The
    // second `yield_no_partner` condition (`baselineSignature(X)` lookup misses) reads it without
    // another store read.
    var liveBySignature: [RuleSignature: [String]] = [:]
    for row in state.live {
        guard let identity = row.syncId,
              let signature = URLRuleKind.signature(of: row, resolve: resolve,
                                                    normalize: normalize) else { continue }
        context.localSignatures[identity] = signature
        liveBySignature[signature, default: []].append(identity)
        if URLRuleKind.isAtRest(row: row, cursor: input.table.cursors[identity], resolve: resolve,
                                normalize: normalize, tombstonesThisPage: input.tombstoned) {
            out.atRestIdentities.insert(identity)
        }
    }
    out.plan = SyncableOwnedItems.plan(URLRuleKind.self, arrivals: arrivals, parked: input.parked,
                                       table: input.table, resolve: input.maps.resolver,
                                       context: context)
    out.mustRepublish = normalized.normalized.union(out.plan.mustRepublish)
        .union(claims.mustRepublish)

    // §13.2 `yield_no_partner` (R-M3-4a-75(3)) requires both `mergePartnerSyncId == nil` on the
    // current row and a failed `baselineSignature(X)` lookup. The module cannot see either input,
    // so count here using the same pre-pass rows and signature index. These are the exact inputs at
    // the decision point. Never infer this count from `resurrected`, which combines both causes.
    var rowBySyncId: [String: PhiLocalURLRule] = [:]      // Include soft-deleted rows.
    for row in state.rows {
        guard let identity = row.syncId, rowBySyncId[identity] == nil else { continue }
        rowBySyncId[identity] = row
    }
    for identity in out.plan.yieldedTombstones {
        guard rowBySyncId[identity]?.mergePartnerSyncId == nil else { continue }
        let baseline = URLRuleKind.baselineSignature(identity: identity, table: input.table,
                                                     resolve: resolve, normalize: normalize)
        let anchored = baseline.flatMap { liveBySignature[$0] }?
            .contains { $0 != identity } ?? false
        if !anchored { out.yieldNoPartner += 1 }
    }

    // Two §8.4.4 `.transfer` details:
    // 1. Remove `serverBytes` (ruling 8). A (β) transfer resolved from a parked payload must return
    // `outcome.landed` to clear `pendingApply` without writing `reconciled` or `server`. The engine
    // writes each only when present. Removing bytes is harmless for (α), whose `outcome.deleted`
    // path never reads them, and essential for (β); otherwise the payload remains in the cursor and
    // is reconsidered every round, keeping `parked` nonzero.
    // 2. Do not count `transferred` or §13.3 here. Ruling 9's per-unit LWW compares against `max(W
    // row stamp, W effective account stamp)`, but this page's `.update(W)` has not landed and
    // effective account stamps are not computed yet (CASE M-34 variants b / c). The landing
    // transaction returns both `OwnedLandingOutcome.transferred` and `.supersededByDelete`.
    for step in out.plan.steps {
        guard case .transfer = step.kind else { continue }
        out.serverBytes.removeValue(forKey: step.identity)
    }
    return out
}

/// §8.4.2 M1 claim output, keyed by identity.
private struct URLRuleClaimPlan {
    /// Identity -> local row `id` (`context.pairs` / `OwnedPlanOutput.claimedLocalIds`).
    var pairs: [String: String] = [:]
    /// Identity -> superseded old `syncId` (`OwnedPlanOutput.retiredIdentities`).
    var retired: [String: String] = [:]
    /// Identity -> §8.2 merge without a baseline (`context.adoptedMerges`).
    var merges: [String: Data] = [:]
    /// Identities whose merged values differ from the current row projection
    /// (`context.adoptedFieldWrites`, plan ruling 5).
    var fieldWrites: Set<String> = []
    /// Identities whose merged values differ from the inbound entity: any locally winning unit
    /// requires republishing.
    var mustRepublish: Set<String> = []
}

/// §8.4.2 M1 claim pre-pass:
/// 1. Build `access.signatureIndex(resolve:)` from this page's read, excluding soft-deleted rows
/// and sorting each group by `(syncId ?? "", id)`.
/// 2. Compute entity signatures for arrivals ∪ parked entities; arrivals override parked payloads
/// with the same identity. Group by signature.
/// 3. Sort remote identities lexically, retain local index order, and pair 1:1 by position as in
/// `pairWithinGroups`. Leave both sides' surplus unpaired (RR3-4 / RR3-16, CASE M-13).
/// 4. Require each local candidate to be unpublished: no cursor, or `entityId.isEmpty && server ==
/// nil && reconciled == nil`. Rows with baselines or cursors retained after birthday reset cannot
/// be claimed (CASE M-2 / M-2b).
/// 5. Populate `pairs` / `retired` for each match.
/// 6. Merge through §8.2's no-baseline branch, stamping the local projection with `baseline: nil`
/// under R-M3-4a-12's three rules; store the result in `merges`.
/// 7. Record differences from the row projection in `fieldWrites`, and differences from the inbound
/// entity in `mustRepublish`.
/// Exclude inbound identities already represented locally, including soft-deleted rows:
/// identity-based landing must never create a second row on replay. Also exclude local rows whose
/// `syncId` arrives on this page, because that arrival already addresses them by identity. Both
/// exclusions avoid redundant re-keying.
@MainActor
private func urlRuleClaims(arrivals: [OwnedItemArrival<Phi_PhiURLRuleEntity>],
                           parked: [String: ParkedOwnedItem],
                           table: PhiOwnedItemTable,
                           resolve: OwnerResolver,
                           now: Int64,
                           access: any PhiURLRuleLocalAccess,
                           state: URLRuleSyncRoundState) -> URLRuleClaimPlan {
    var out = URLRuleClaimPlan()
    let normalize = URLRuleSignatureQueries.normalize
    let localIdentities = Set(state.rows.compactMap(\.syncId))

    var candidates: [String: Phi_PhiURLRuleEntity] = [:]
    for (identity, item) in parked {
        guard let envelope = try? Phi_PhiEntity(serializedBytes: item.payload),
              let entity = URLRuleKind.entity(from: envelope) else { continue }
        candidates[identity] = entity
    }
    for item in arrivals {
        candidates[URLRuleKind.identity(of: item.entity)] = item.entity
    }
    let arrivingIdentities = Set(candidates.keys)

    var remoteGroups: [RuleSignature: [(identity: String, entity: Phi_PhiURLRuleEntity)]] = [:]
    for (identity, entity) in candidates where !identity.isEmpty && !localIdentities.contains(identity) {
        guard let signature = URLRuleKind.signature(of: entity, resolve: resolve,
                                                    normalize: normalize) else { continue }
        remoteGroups[signature, default: []].append((identity, entity))
    }
    guard !remoteGroups.isEmpty else { return out }

    let index = access.signatureIndex(resolve: resolve)
    for (signature, remotes) in remoteGroups {
        let orderedRemote = remotes.sorted { $0.identity < $1.identity }
        let orderedLocal = (index[signature] ?? []).filter { row in
            guard let syncId = row.syncId, !arrivingIdentities.contains(syncId) else { return false }
            guard let cursor = table.cursors[syncId] else { return true }
            return cursor.entityId.isEmpty && cursor.server == nil && cursor.reconciled == nil
        }
        for (offset, remote) in orderedRemote.enumerated() where offset < orderedLocal.count {
            let row = orderedLocal[offset]
            guard let previous = row.syncId,
                  let projected = URLRuleKind.project(row, resolve: resolve, scope: nil,
                                                      parentIdentity: nil) else { continue }
            let rank = URLRuleKind.rank(of: remote.entity)
            // Stamp the local projection without a baseline (R-M3-4a-12), then replace its identity
            // with the claimed account identity. Both the merge and baseline must use that
            // identity; retaining the old `syncId` in `reconciled` would make every later snapshot
            // differ.
            // hlcMax stays 0: this is the local side of a claiming merge, not a publication, and
            // AM-1's logical floor would let an old untouched local rule beat the arrival it is
            // claiming (the same reason the bookmark adoption projection passes 0).
            var local = URLRuleKind.stamp(projected, baseline: nil, local: row, rank: rank,
                                          now: now, hlcMax: 0)
            local.ruleUuid = remote.identity
            let merged = URLRuleKind.merge(local: local, remote: remote.entity)
            guard let mergedBytes = try? URLRuleKind.envelope(merged).serializedData() else { continue }
            out.pairs[remote.identity] = row.id
            out.retired[remote.identity] = previous
            out.merges[remote.identity] = mergedBytes
            if mergedBytes != (try? URLRuleKind.envelope(local).serializedData()) {
                out.fieldWrites.insert(remote.identity)
            }
            if mergedBytes != (try? URLRuleKind.envelope(remote.entity).serializedData()) {
                out.mustRepublish.insert(remote.identity)
            }
        }
    }
    return out
}

/// The URL-rule counterpart of `bookmarkLocalProjections`: identity -> current outbound row
/// projection, using `URLRuleKind.stamp` with a baseline, not the no-baseline adoption rule. Skip
/// identities without a live local row or cursor baseline. The bookmark exclusion for a parent
/// lacking identity does not apply: rules have no parent.
@MainActor
private func urlRuleLocalProjections(for identities: Set<String>,
                                     table: PhiOwnedItemTable,
                                     resolve: OwnerResolver,
                                     now: Int64,
                                     state: URLRuleSyncRoundState) -> [String: Data] {
    guard !identities.isEmpty else { return [:] }
    var out: [String: Data] = [:]
    for row in state.live {
        guard let identity = row.syncId, identities.contains(identity), out[identity] == nil,
              let baselineBytes = table.cursors[identity]?.reconciled,
              let baselineEnvelope = try? Phi_PhiEntity(serializedBytes: baselineBytes),
              let baseline = URLRuleKind.entity(from: baselineEnvelope),
              let projected = URLRuleKind.project(row, resolve: resolve, scope: nil,
                                                  parentIdentity: nil) else { continue }
        // Use the baseline rank, as for bookmarks: inbound merging must not trigger account-wide
        // ordering.
        let stamped = URLRuleKind.stamp(projected, baseline: baseline, local: row,
                                        rank: URLRuleKind.rank(of: baseline), now: now)
        guard let bytes = try? URLRuleKind.envelope(stamped).serializedData() else { continue }
        out[identity] = bytes
    }
    return out
}

/// §8.4.3 landing tail-hook assembly (8b-2 ruling 3).
/// Intentionally not `@MainActor`: this closure runs on the write queue at the end of the landing
/// transaction. Creating it inside `@MainActor landURLRules` would infer actor isolation that
/// cannot be retained by `URLRuleMergeTail.evaluate`'s nonisolated function type. Captures are
/// values (cursor table, two dictionaries, three sets, and resolver closures reading immutable
/// dictionaries), and `URLRuleKind.mergePass` is pure, so evaluation across executors shares no
/// mutable state.
private func makeURLRuleMergeTail(landedThisPage: Set<String>,
                                  publishedIdentities: Set<String>,
                                  preLandingSignatures: [String: RuleSignature],
                                  atRest: Set<String>,
                                  landed: [String: URLRuleLandingValues],
                                  rebaselined: [String: Data],
                                  table: PhiOwnedItemTable,
                                  convergeAllowed: Bool,
                                  resolve: OwnerResolver) -> URLRuleMergeTail {
    URLRuleMergeTail { rows in
        URLRuleKind.mergePass(rows: rows,
                              landedThisPage: landedThisPage,
                              publishedIdentities: publishedIdentities,
                              preLandingSignatures: preLandingSignatures,
                              atRest: atRest,
                              landed: landed,
                              rebaselined: rebaselined,
                              table: table,
                              convergeAllowed: convergeAllowed,
                              resolve: resolve)
    }
}

/// §4.4 / §4.5 URL-rule landing: translate steps, project dense order in both buckets, apply one
/// transaction, then verify.
/// Each step becomes an operation addressed by `identity` / `syncId`. `.create` creates only when
/// no local row exists; an existing row, including a soft-deleted one, becomes `.update` / `.move`
/// (R-M3-4a-42(a)), preventing duplicates after cursor loss or marker rollback. `.update` maps
/// directly; `.move` uses `step.newOwnerUuid` (R-M3-4a-26); `.delete` uses `syncId`; `.claim`
/// becomes `.rekey(localId:to:values:)` using `input.claimedLocalIds[identity]` (§8.4.2 M1, ruling
/// 2).
/// `URLRuleApplyBatch.init` combines same-identity `.move` + `.update`, reduces a same-target move
/// to `.reorder` (CASE U-10b), and folds `.claim` + `.update` into one `.rekey` (R-M3-4a-42(b)).
@MainActor
private func landURLRules(_ input: OwnedLandingInput,
                          access: any PhiURLRuleLocalAccess,
                          state: URLRuleSyncRoundState) async -> OwnedLandingOutcome {
    var out = OwnedLandingOutcome()
    // Do not return early when this page has no rule steps (8b-2 / R-M3-4a-56). M2 still needs its
    // transaction. Otherwise local-only duplicates and pages containing only other kinds never
    // converge; those pages dominate steady state after drain (CASE M-35).
    let resolve = input.maps.resolver

    /// Account target -> local `spaceId`. Map the reserved constant back to the bare Incognito
    /// prefix (R-M3-4a-7).
    func localSpaceId(_ target: String) -> String? {
        if target == SyncableSpaces.incognitoSpaceUuid { return SpaceManager.incognitoRuleTargetId }
        return resolve.localSpaceId(target)
    }

    // Identity -> local row, including soft-deleted rows. Landing addresses `syncId`, so
    // resurrection is an update. Prefer live rows.
    var rowOf: [String: PhiLocalURLRule] = [:]
    for row in state.live {
        guard let identity = row.syncId, rowOf[identity] == nil else { continue }
        rowOf[identity] = row
    }
    for row in state.rows {
        guard let identity = row.syncId, rowOf[identity] == nil else { continue }
        rowOf[identity] = row
    }
    // Local row id -> row. `.claim` addresses the local id (§8.4.2), while the row still carries
    // its old identity.
    var rowById: [String: PhiLocalURLRule] = [:]
    for row in state.rows { rowById[row.id] = row }
    // Identity -> rank for this round: start with baselines, then override with this page's merged
    // results. Untouched siblings in affected buckets use baseline ranks. Unpublished rows lack
    // ranks and `rankToSortOrder` puts them first.
    var rankOf: [String: String] = [:]
    for (identity, cursor) in input.table.cursors {
        guard let bytes = cursor.reconciled,
              let envelope = try? Phi_PhiEntity(serializedBytes: bytes),
              let entity = URLRuleKind.entity(from: envelope) else { continue }
        rankOf[identity] = URLRuleKind.rank(of: entity)
    }

    struct Landing {
        var entity: Phi_PhiURLRuleEntity
        var payload: Data
        var spaceId: String
        var row: PhiLocalURLRule?
        var moves = false
        var writesContent = false
        /// §8.4.2 M1: local row `id` to claim for this identity; `row` still carries the old
        /// `syncId`.
        var claimsLocalId: String?
    }
    var order: [String] = []
    var landing: [String: Landing] = [:]
    var deleteIdentities: [String] = []
    /// §8.4.4 edit transfers (8b-3): X's identity, source projection, and partner W's identity.
    /// Keep these outside `landing`: they write values into W, rather than landing a remote entity.
    var transfers: [(identity: String, source: RuleProjection, to: String)] = []

    for step in input.steps {
        let identity = step.identity
        var claimedLocalId: String?
        var claimedRow: PhiLocalURLRule?
        switch step.kind {
        case .delete:
            deleteIdentities.append(identity)
            continue
        case .transfer(let source, let to):
            transfers.append((identity: identity, source: source, to: to))
            continue
        case .claim:
            // §8.4.2 M1: locate the local row through `claimedLocalIds`. A missing mapping, missing
            // row, or soft-deleted row indicates an invalid batch. Refuse it; parking would retry
            // the same invalid pairing every round.
            guard let localId = input.claimedLocalIds[identity],
                  let row = rowById[localId], row.deletedDate == nil else {
                out.refused.insert(identity)
                landing.removeValue(forKey: identity)
                continue
            }
            claimedLocalId = localId
            claimedRow = row
        case .create, .move, .update:
            break
        }
        guard !out.parked.contains(identity), !out.refused.contains(identity) else { continue }
        guard let payload = step.payload,
              let envelope = try? Phi_PhiEntity(serializedBytes: payload),
              let entity = URLRuleKind.entity(from: envelope) else {
            // An undecodable planned payload indicates an invalid batch. Refuse it instead of
            // parking the same failure for every round.
            out.refused.insert(identity)
            landing.removeValue(forKey: identity)
            continue
        }
        let target: String
        if step.kind == .move {
            guard let newOwner = step.newOwnerUuid else {
                // Task 7 populates every `.move` with `targetOwnerUuid(of: merged)` (R-M3-4a-26);
                // nil is unreachable.
                assertionFailure("url rules: .move without newOwnerUuid for \(identity.prefix(8))")
                out.refused.insert(identity)
                landing.removeValue(forKey: identity)
                continue
            }
            target = newOwner
        } else {
            target = URLRuleKind.targetOwnerUuid(of: entity) ?? ""
        }
        // If the owner has not landed yet (Space mapping arrives a round later), park the entity
        // and update the existing row next round.
        guard let spaceId = localSpaceId(target) else {
            out.parked.insert(identity)
            landing.removeValue(forKey: identity)
            continue
        }
        if landing[identity] == nil {
            order.append(identity)
            landing[identity] = Landing(entity: entity, payload: payload, spaceId: spaceId,
                                        row: claimedRow ?? rowOf[identity],
                                        claimsLocalId: claimedLocalId)
        }
        // Steps for the same identity carry the same merge result; the later step overwrites the
        // earlier one.
        landing[identity]?.entity = entity
        landing[identity]?.payload = payload
        landing[identity]?.spaceId = spaceId
        switch step.kind {
        case .move: landing[identity]?.moves = true
        case .claim: break      // Write identity only; content uses `.update` via `adoptedFieldWrites`.
        default: landing[identity]?.writesContent = true
        }
        rankOf[identity] = URLRuleKind.rank(of: entity)
    }
    let active = order.filter { landing[$0] != nil }

    // Phase 3: deletion. §5.6 T3: if identity lookup succeeds but no local row exists, delete
    // nothing and still record cursor `deletedAtMs`.
    var deleteOps: [URLRuleSyncOp] = []
    var deletedWithRow: Set<String> = []
    var touched: Set<String> = []
    for identity in deleteIdentities {
        guard let row = rowOf[identity] else {
            out.landed.insert(identity)
            out.deleted.insert(identity)
            continue
        }
        deleteOps.append(.delete(syncId: identity))
        deletedWithRow.insert(identity)
        touched.insert(row.spaceId)
    }

    // Affected buckets: creates, resurrections, and reorders affect the target; rehomes affect both
    // source and target (R-M3-4a-3). Content-only updates leave ordering unchanged, as in
    // `landPins`. Claimed rows receive an account rank for the first time (§8.4.2), so they affect
    // the target just like creates.
    for identity in active {
        guard let item = landing[identity] else { continue }
        if let row = item.row {
            if row.spaceId != item.spaceId {
                touched.insert(row.spaceId)
                touched.insert(item.spaceId)
            } else if item.moves || row.deletedDate != nil || item.claimsLocalId != nil {
                touched.insert(item.spaceId)
            }
        } else {
            touched.insert(item.spaceId)
        }
    }

    // §8.3 projection: run `rankToSortOrder` once per affected bucket. Its domain is rows in that
    // bucket from this page's read, minus rows moved out or deleted, plus rows moved in, created,
    // or resurrected. The projection itself excludes soft-deleted rows. If a page reread failed,
    // the siblings cache is unavailable (the production implementation asserts); use the round
    // projection's same rows instead.
    var sortOrderOf: [String: Int] = [:]
    let claimedLocalIds = Set(active.compactMap { landing[$0]?.claimsLocalId })
    for bucket in touched {
        var members = state.pageReloadFailed
            ? state.live.filter { $0.spaceId == bucket }
            : access.siblings(inSpaceId: bucket)
        members.removeAll { row in
            // The snapshot still carries claimed rows under their old `syncId`; remove them here
            // and reinsert them below with the new identity.
            if claimedLocalIds.contains(row.id) { return true }
            guard let identity = row.syncId else { return false }
            if deletedWithRow.contains(identity) { return true }
            if let item = landing[identity] { return item.spaceId != bucket }
            return false
        }
        var present = Set(members.compactMap(\.syncId))
        for identity in active {
            guard let item = landing[identity], item.spaceId == bucket,
                  !present.contains(identity) else { continue }
            present.insert(identity)
            if var row = item.row {
                row.spaceId = bucket
                row.deletedDate = nil
                row.syncId = identity
                members.append(row)
            } else {
                // New rows have no local id yet. Projection sorts by `(rank, syncId ?? id)`, so use
                // the identity as a placeholder id.
                members.append(PhiLocalURLRule(
                    id: identity, syncId: identity, spaceId: bucket,
                    host: item.entity.host.stringValue, pathPrefix: nil, askBeforeRouting: false,
                    sortOrder: Int.max, createdDate: Date(), contentUpdatedDate: nil,
                    targetUpdatedDate: nil, deletedDate: nil, pendingLocalEdit: false,
                    mergePartnerSyncId: nil))
            }
        }
        let projected = URLRuleKind.rankToSortOrder(siblings: members, ranks: rankOf)
        for row in members {
            guard let identity = row.syncId, let position = projected[row.id] else { continue }
            sortOrderOf[identity] = position
        }
    }

    /// Convert milliseconds to `Date`, the inverse of `URLRuleKind.milliseconds`.
    func date(_ ms: Int64) -> Date { Date(timeIntervalSince1970: Double(ms) / 1000) }

    // Phases 1 / 2: create / move / update. Each identity supplies one value set; local row
    // existence and bucket changes determine operation kinds, which `URLRuleApplyBatch.init`
    // coalesces by identity.
    var ops: [URLRuleSyncOp] = []
    var payloadOf: [String: Data] = [:]
    /// R-M3-4a-94 layer 1: identity -> values landed on this page. Their two stamps match the bytes
    /// about to enter cursor `reconciled`, so they represent the current account values. The cursor
    /// still contains pre-landing values because bookkeeping follows `land(...)`.
    var landedValues: [String: URLRuleLandingValues] = [:]
    for identity in active {
        guard let item = landing[identity] else { continue }
        payloadOf[identity] = item.payload
        let wirePath = item.entity.pathPrefix.stringValue
        let values = URLRuleLandingValues(
            syncId: identity, spaceId: item.spaceId,
            host: item.entity.host.stringValue,
            // Wire empty string maps to local nil (§8.1).
            pathPrefix: wirePath.isEmpty ? nil : wirePath,
            askBeforeRouting: item.entity.ask.boolValue,
            sortOrder: sortOrderOf[identity] ?? item.row?.sortOrder ?? 0,
            createdDate: date(item.entity.createdAtMs),
            // Persist both remote stamps from the merge result, not `now` (R-M3-4a-20 / 48: the
            // engine does not mint stamps).
            contentUpdatedDate: date(item.entity.host.updatedAtMs),
            targetUpdatedDate: date(item.entity.targetSpaceUuid.updatedAtMs))
        landedValues[identity] = values
        guard let row = item.row else {
            ops.append(.create(values))
            continue
        }
        if let localId = item.claimsLocalId {
            // §8.4.2 M1: re-key by local id. `URLRuleApplyBatch.init` folds the `.update` field
            // values into the same `.rekey`. A changed projected index also requires writing
            // values: the claimed row receives its first account-ranked position. Use the same
            // values write without a separate `.reorder`.
            ops.append(.rekey(localId: localId, to: identity, values: nil))
            let repositioned = sortOrderOf[identity].map { $0 != row.sortOrder } ?? false
            if item.writesContent || repositioned { ops.append(.update(values)) }
            continue
        }
        // §4.5: look up the local row by identity before creating. Every existing row uses update /
        // move.
        if item.moves || row.spaceId != item.spaceId { ops.append(.move(values)) }
        if item.writesContent { ops.append(.update(values)) }
    }
    // Other siblings: emit a reorder for each existing local row whose index changed in an affected
    // bucket on this page.
    for (identity, position) in sortOrderOf where landing[identity] == nil {
        guard let row = rowOf[identity], row.deletedDate == nil, row.sortOrder != position else {
            continue
        }
        ops.append(.reorder(syncId: identity, spaceId: row.spaceId, sortOrder: position))
    }
    ops.append(contentsOf: deleteOps)

    // §8.4.3 M2 assembly (8b-2). Even with empty `ops`, open the same transaction to run the tail
    // hook (R-M3-4a-56 / CASE M-35).
    // Compute three inputs before assembling the batch:
    // 1. First candidate subtraction (ruling 6(1) / R-M3-4a-90): transfer targets whose units are
    // written on this page acquire `pendingLocalEdit`, so at-rest predicate 3 excludes them. The
    // pre-pass ran too early to see that; pass the reduced set to `mergePass(atRest:)` (CASE M-33).
    // The second subtraction runs in the transactional tail hook (R-M3-4a-100 / CASE M-36).
    // 2. `publishedIdentities` (R-M3-4a-95): a non-nil `syncId` does not imply publication. M1
    // assigns an identity during claim, before the round's publish phase obtains the server tuple.
    // 3. The shared effective account-stamp table (R-M3-4a-94 / 97 / 98), used by transfer targets
    // and the tail hook. The hook's `mergePass` recomputes it from the same three arguments; pure
    // evaluation with identical inputs guarantees matching values.
    let landedThisPage = URLRuleKind.landedIdentities(in: input.steps)
    let transferTargets = URLRuleKind.transferTargets(in: input.steps)
    let mergeCandidates = input.atRestIdentities.subtracting(transferTargets)
    let publishedIdentities = Set(input.table.cursors.filter { $0.value.server != nil }.keys)
    let stampIdentities = Set(state.live.compactMap(\.syncId))
        .union(landedThisPage).union(transferTargets)
    let accountStamps = URLRuleKind.effectiveAccountStamps(landed: landedValues,
                                                           rebaselined: input.rebaselined,
                                                           table: input.table,
                                                           identities: stampIdentities)
    // §8.4.4 phase 3 (R-M3-4a-93): one operation per step. Read W's target stamps from the shared
    // effective account-stamp table through the R-M3-4a-98 input; add no protocol member or
    // independent cursor lookup. If W is absent, pass an empty value so the primitive's `max`
    // reduces to the row stamp. `fromSyncId` supplies R-M3-4a-102's transactional reread of X to
    // verify that the source row is unchanged.
    for transfer in transfers.sorted(by: { $0.identity < $1.identity }) {
        ops.append(.transfer(fromSyncId: transfer.identity, toSyncId: transfer.to,
                             source: transfer.source,
                             targetEffectiveStamps: accountStamps[transfer.to]
                                 ?? URLRuleEffectiveStamps()))
    }
    let mergeTail = makeURLRuleMergeTail(landedThisPage: landedThisPage,
                                         publishedIdentities: publishedIdentities,
                                         preLandingSignatures: input.preLandingSignatures,
                                         atRest: mergeCandidates,
                                         landed: landedValues,
                                         rebaselined: input.rebaselined,
                                         table: input.table,
                                         convergeAllowed: input.convergeAllowed,
                                         resolve: resolve)
    // §5.5: a thrown transaction lands nothing, so park the whole batch, including transfer
    // identities. In (α), X is tombstoned; parking sets its `pendingTombstone` for reevaluation
    // next round.
    let identities = Set(active).union(deletedWithRow).union(transfers.map(\.identity))
    let batch = URLRuleApplyBatch(unordered: ops, currentSpaceIds: state.currentSpaceIds,
                                  mergeTail: mergeTail, accountStamps: accountStamps)
    let batchOutcome: URLRuleBatchOutcome
    do {
        batchOutcome = try await access.apply(batch)
    } catch {
        // §5.5: one transaction; a throw lands nothing, so park the batch for retry. Invalid
        // landing plans (`rowAlreadyMapped`) are refused instead, using the same classification as
        // `landPins`.
        if case LocalStoreWriteError.rowAlreadyMapped = error {
            out.refused.formUnion(identities)
        } else {
            out.parked.formUnion(identities)
        }
        return out
    }
    // §8.4.3 M2 outcome: two fields (8b-2).
    out.collapsed = batchOutcome.collapsed
    out.mergeChangedRouting = batchOutcome.mergeChangedRouting
    // §8.4.4 M3 outcome: three fields (8b-3). The engine accounts for `deferredTombstones` through
    // `plan.parkedTombstones`; those identities appear in neither `landed` nor `deleted`, and both
    // loops below skip them.
    out.transferred = batchOutcome.transferred
    out.supersededByDelete = batchOutcome.transferSupersededByDelete
    out.deferredTombstones = batchOutcome.deferredTombstones
    // R-M3-4a-62 first incremental update: immediately fold committed re-keys into the round
    // projection as local row id -> new syncId, opposite to the bookmark mapping direction (ruling
    // 3).
    var persisted: [String: String] = [:]
    for op in batch.ops {
        if case .rekey(let localId, let to, _) = op { persisted[localId] = to }
    }
    if !persisted.isEmpty { access.notePersistedClaims(persisted) }
    // §4.5: verify the plan after landing and before writing baselines. `apply` has already rebuilt
    // its cache, so this lookup sees committed rows. Verify before the reread below, so a failed
    // reread cannot make landed rows appear absent.
    for identity in active {
        guard access.isKnownLocalURLRule(identity) else {
            out.parked.insert(identity)
            continue
        }
        out.landed.insert(identity)
        if let payload = payloadOf[identity] { out.reconciled[identity] = payload }
    }
    var deletedRows: Set<String> = []
    for identity in deletedWithRow {
        // R-M3-4a-102: if the source changed, neither `.transfer` nor `.delete(X)` ran. Exclude X
        // from `landed` and `deleted`; marking it deleted would acknowledge a hard delete that
        // never happened, causing the next diff to recreate its surviving row. Also exclude it from
        // `parked`: `deferredTombstones` supplies its retry bookkeeping.
        guard !batchOutcome.deferredTombstones.contains(identity) else { continue }
        if access.isKnownLocalURLRule(identity) {
            out.parked.insert(identity)
        } else {
            out.landed.insert(identity)
            out.deleted.insert(identity)
            deletedRows.insert(identity)
        }
    }
    // §8.4.4 (β) cleanup (ruling 8): a transfer resolved from a parked payload must clear
    // `X.cursor.pendingApply` and `pendingOwnerUuid` in the same landing. Return the identity in
    // `outcome.landed`, where the engine clears both. Omit `outcome.reconciled[X]` and
    // `output.serverBytes[X]` (already removed by the plan closure), so neither baseline is written
    // and neither `deletedDate` nor `pendingDelete` is cleared.
    // (α) does not use this path: X follows the deletion path above or `deferredTombstones`.
    for transfer in transfers {
        guard !deleteIdentities.contains(transfer.identity) else { continue }
        out.landed.insert(transfer.identity)
    }
    // R-M3-4a-62 second incremental update: immediately remove rows actually deleted on this page
    // from the projection. Never remove yielding identities here (R-M3-4a-61): 8b-3 branch (ii)
    // soft-deletes them, and they remain in the projection awaiting their own tombstones.
    if !deletedRows.isEmpty { access.noteDeletedRows(deletedRows) }
    // R-M3-4a-62: reread this page's row projection once after commit.
    state.reloadAfterPage(access)
    // §6.6 row 1 / R-M3-4a-34: landing explicitly refreshes routing once per page.
    // §6.6 row 8 (8b-2 ruling 7 / R-M3-4a-56) supplies the second disjunct. On convergence-only
    // pages with no landing, losers are already soft-deleted but remain in Chromium's routing
    // table. Without this condition, correction waits for another landing, just as with rules
    // retained after a remote Space deletion. Pointer-only writes must not trigger refresh:
    // `mergePartnerSyncId` is absent from the routing table (CASE M-7 asserts zero refreshes). M3
    // edit transfers need no ninth row because they occur during landing and the first disjunct
    // covers them (§8.4.7).
    if !ops.isEmpty || out.mergeChangedRouting {
        access.refreshRoutingTableAfterLanding()
    }
    // §13.2 `owner_moved`: count `.move` operations that survive batch coalescing (ruling 3).
    out.ownerMoved = batch.ops.reduce(into: 0) { sum, op in
        if case .move = op { sum += 1 }
    }
    // Rules always leave `createdRows` / `createdPins` empty (no icon backfill),
    // `pendingPartnerLineages` empty, and `relineaged` zero.
    return out
}

#if DEBUG
extension PhiSyncEngine {
    /// Read-only test access. Tests drive the engine through existing entries such as `pullOnce()`,
    /// `setSpaceSyncEnabled(_:)`, and `previewAccountSpaces()`; these expose only the resulting
    /// state.
    /// All accessors are actor-isolated. Await each value before asserting: `XCTAssert*` uses
    /// autoclosures that cannot directly evaluate `await`. Task 6 adds cursor-table and counter
    /// accessors here once the engine owns that state.
    var spaceTableForTesting: PhiSpaceSyncTable { loadSpaceTable() }

    /// Get a registered kind's cursor table for this round by label. Read the engine's in-memory
    /// mirror, not the store: an assertion must not add a load that disrupts
    /// `MemoryOwnedItemStore.loseOnLoadNumber` or `hadRecordsSeen` scripts.
    func ownedTableForTesting(_ label: String) -> PhiOwnedItemTable {
        ownedTables[label] ?? PhiOwnedItemTable()
    }

    /// Latest round's per-kind counters (§11.2), keyed by label.
    var lastOwnedRoundCountersForTesting: [String: OwnedRoundCounters] { ownedCounters }

    /// Pages visited and entities counted by the latest preview (§5.8). Reset at round start and
    /// written on every exit: success, truncation, deadline, retirement, and transport failure.
    /// This prevents stale values from a previous preview.
    /// This independent read-only accessor is not a `.truncated` associated value. Adding one would
    /// break the wizard's two existing `case .truncated:` matches and assertions in two test files
    /// without changing what they represent.
    var lastPreviewStatsForTesting: (pages: Int, entities: Int) { lastPreviewStats }

    /// Four read-only B-2 outcome accessors (Task 2b, §2.8). Read the `LoggedRound` snapshot
    /// captured when `run(_:)` emits its outcome, rather than live counters. A
    /// `page_budget_exhausted` outcome queues a follow-up whose `run(_:)` resets live counters;
    /// assertions might otherwise observe the next round's values. nil / 0 / false mean this engine
    /// has not completed a round yet. These add no driving entry points.
    var lastRoundOutcomeForTesting: RoundOutcome? { lastLoggedRound?.outcome }
    /// Pages fetched in the latest round, accumulated across pulls within that round. Read-only.
    var lastRoundPagesForTesting: Int { lastLoggedRound?.pages ?? 0 }
    /// Whether the persisted marker moved in the latest round (plan ruling 7). Read-only.
    var lastRoundMarkerAdvancedForTesting: Bool { lastLoggedRound?.markerAdvanced ?? false }
    /// Failure count reported by the four persistence paths in the latest round. Read-only.
    var lastRoundCursorSaveFailedCountForTesting: Int { lastLoggedRound?.cursorSaveFailures ?? 0 }
}
#endif

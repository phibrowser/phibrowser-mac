// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import CryptoKit
import Foundation

extension Notification.Name {
    /// Posted at the end of EVERY `SyncKeyController.resolveMappings()` pass,
    /// the ones that bail out early included, by `clearResolved()`, and as
    /// `.held` when a Profile leaves `profileIdsBeingCreated` without an adopt
    /// (no pass follows that one). The
    /// single hook that says "the profile mapping picture may have changed" --
    /// today nothing broadcasts that and the Devices pane polls a closure every
    /// 3 s.
    ///
    /// userInfo: `SyncKeyController.mappingsOutcomeKey` carries a
    /// `SyncKeyController.MappingsOutcome` raw value on every announcement this
    /// controller posts. Observers that read the two pairing predicates MUST
    /// branch on it: see that type's own comment for why the three cases are not
    /// interchangeable.
    static let phiProfileMappingsDidResolve = Notification.Name("phiProfileMappingsDidResolve")

    /// Posted by `ensureLocalProfilesForAccount()` immediately before EVERY
    /// return, `.failed` and `.skipped` included, except a round that the
    /// controller's `retire()` stopped: that one returns `.failed` silently. userInfo:
    ///   outcome:      "unchanged" | "changed" | "skipped" | "failed"
    ///   created:      Int   // profiles actually created + adopted this round
    ///   skippedUuids: Int   // account uuids left unclaimed this round
    /// `"skipped"` means the round deliberately did not run at all -- the join
    /// pairing gate was shut -- and is NOT a failure: nothing was attempted, so
    /// there is nothing to retry and no error to report.
    /// `ProfilePairingGate`'s hysteresis counter advances on THIS and nothing else.
    static let phiProfileAutoCreateDidRun = Notification.Name("phiProfileAutoCreateDidRun")
}

/// A pairing decision applied by the pairing UI (a later task) to resolve an
/// ambiguous local-profile <-> remote-profile mapping. `createLocal` is
/// deferred to that UI for the actual bridge profile creation; this type
/// only records the intent.
enum PairingDecision: Equatable {
    case adopt(localProfileId: String, remoteUuid: String)
    case registerNew(localProfileId: String, displayName: String)
    case createLocal(remoteUuid: String, displayName: String)
}

/// The bits of `ProfileManager` the key layer needs to create a local Chromium
/// profile. Injected so the auto-create can be unit tested with no bridge -- and
/// so `ProfileManager` stops being a direct dependency of the pairing UI.
@MainActor
protocol LocalProfileCreating: AnyObject {
    var userAssignableProfileIds: [(profileId: String, displayName: String)] { get }
    func displayNameExists(_ name: String) -> Bool
    func createProfile(displayName: String) async -> String?
}

enum NativeSyncResetError: Error { case cleanupFailed }

/// App-scoped owner of the sync key layer: silently unlocks the ARK at
/// startup/login, resolves local-profile -> global-profile mappings, caches
/// per-profile sync info for the bridge's synchronous hot-path pull, and pings
/// Chromium when keys become available. Owned by PhiChromiumCoordinator; the
/// Devices settings pane consumes this shared instance (ownership change from
/// M2-3's per-pane factory, documented in the M2-4 design).
@MainActor
final class SyncKeyController {
    let manager: AccountKeyManager
    let approvals: DeviceApprovalService
    let profileKeys: ProfileKeyManager
    /// D6 §2.2 local spaceId ↔ account syncUuid mapping layer. Nil means no Space section, like
    /// spaceStateStore, for tests/unwired construction. Never provide an in-memory default: reminting on every
    /// launch would duplicate account Spaces. Nil fails by publishing nothing, exposed via unmapped counts
    /// (§9.3).
    let spaceKeys: SpaceSyncMappingManager?

    private let localProfilesProvider: () -> [(profileId: String, displayName: String)]
    private let notifyChromium: () -> Void
    private let profileCreator: any LocalProfileCreating
    /// Shuts the settings/Space engine down and unhooks it. Injected as a closure
    /// (never a direct singleton reference) so the self-revoke tests do not reach
    /// the real `PhiChromiumCoordinator.shared`.
    private let retirePhiSync: (Bool) -> Void
    private let invalidateEnrollment: () throws -> Void
    private let finishLocalCleanup: (Bool) -> Void
    private let verifyCursorDeletion: () throws -> Void
    private let isCurrentAccount: () -> Bool
    private var cleaningLocalState = false
    private let runtimeRequiresReconfiguration: () -> Bool
    private let runtimeRemovalPending: () -> Bool
    /// True while confirmed cleanup is unfinished. A journaled account reset counts: its
    /// `resetOperationId` is the durable mark of a reset whose outcome this Mac has not
    /// recorded yet, so it must resume through Set up sync again (`reconfigureSync()`) and
    /// never be replayed against an account set up afresh. While the reset request is in
    /// flight the flag is momentarily true as well, which keeps the pairing reset out.
    var requiresReconfiguration: Bool {
        let journal = markerStore?.load()
        return journal?.requiresReconfiguration == true || journal?.resetOperationId != nil
            || runtimeRequiresReconfiguration()
    }

    /// Whether Set up sync again will finish a journaled account reset (and so delete the
    /// account's sync data) rather than only clear this Mac's sync setup. The confirmation
    /// copy follows it.
    var resetResumePending: Bool { markerStore?.load().resetOperationId != nil }

    private let isPairingComplete: @MainActor () -> Bool
    /// `ProfileManager.isProfileListEnumerated`: until the list has been read once, an
    /// empty `localProfilesProvider()` answer says nothing about which Profiles exist, so
    /// the unmapped evidence is not pruned against it (docs/sync.md, "Enrollment and setup").
    private let isProfileListEnumerated: @MainActor () -> Bool
    /// The drained account's Profile entities (`PhiSpaceSyncState.accountProfileEntityView`).
    /// Auto-create and the registration wait follow it rather than the key registry, which never
    /// forgets a deleted Profile (docs/sync.md, "Enrollment and setup"). The closure answers nil
    /// before the first full replay. A nil closure (tests, unwired construction) applies no gating.
    private let profileEntityView: (@MainActor () -> AccountProfileEntityView?)?
    private let deviceKeyRotator: (any DeviceKeyRotating)?
    private let engineDefaults: UserDefaults
    private let spaceStateStore: (any PhiSpaceSyncStateStore)?
    /// M3-3 §9.1 per-kind bookmark/pin cursor stores, whose files are deleted during self-revocation rather
    /// than saved empty. An empty array means no owned-item section for tests/unwired construction. Retain
    /// stores, not URLs: PhiOwnedItemStateStore.deleteFile owns deletion and avoids duplicating §3.5 paths.
    private let ownedItemStores: [any PhiOwnedItemStateStore]
    /// M3-4a §4.4 self-revocation also deletes account marker.json, containing shared progress and store
    /// birthday. It is not a cursor table, so stays outside ownedItemStores. Nil means unwired/test
    /// construction, like the empty array.
    private let markerStore: (any PhiSyncMarkerStore)?
    /// Second half of M3-3 §9.1: clear local syncId columns while preserving rows. A narrow closure like
    /// notifyChromium keeps the controller independent of Account/LocalStore and lets self-revocation tests
    /// avoid the real database.
    private let clearAllSyncIds: (@Sendable () async throws -> Void)?
    /// The account's `sync.pairingLocalReset` marker (docs/sync.md, "Replacing this Mac's data at
    /// pairing"). Nil means unwired/test construction.
    private let localResetMarker: SyncPairingLocalResetMarkerStore?
    /// Local data access for the pairing reset, wired by the coordinator. Nil means unwired/test
    /// construction, and `localDataReset()` then answers nil.
    private let localResetAccess: PhiLocalDataReset.LocalAccess?
    /// The Profile deletion journal the reset's no-history check reads. Defaults to the facade's
    /// account-bound store; nil from it means the journal cannot be read.
    private let profileDeletionIntents: @MainActor () -> (any PhiProfileDeletionIntentStore)?

    /// What an announcement says about the two pairing predicates it arrives
    /// with. `false, false` is produced by all three cases and means something
    /// different in each, so an observer that acts on the predicates has to read
    /// this as well.
    ///
    /// Only `.measured` may retire a pending join's pairing gate: it is the only
    /// case in which this pass actually looked at the account and this Mac and
    /// found them one-to-one. A consumer that treats `.held` or `.cleared` as an
    /// answer drops the join flag on the first offline launch and can never
    /// present the blocking modal again -- and the profiles that existed on both
    /// sides before this device joined are the one thing only that modal can
    /// resolve.
    enum MappingsOutcome: String {
        /// The pass ran the register/adopt decision to the end and ASSIGNED both
        /// predicates from a fully known picture. The only trustworthy answer.
        case measured
        /// The pass bailed out with nothing measured -- the account listing threw
        /// (offline / 5xx / 401 / locked), or some local profile's own lookup did,
        /// which poisons the decision for every other local. Both predicates are
        /// HELD at whatever the last `.measured` pass left them, which on a fresh
        /// controller is the initial `false, false`: never a measurement at all.
        case held
        /// `clearResolved()`: the key layer is gone (locked ARK, sign-out,
        /// teardown, a startup unlock that threw before the account key was held, a
        /// 404 for this device), both predicates were reset to
        /// `false`, and they mean UNKNOWN.
        case cleared
    }

    /// `userInfo` key on `.phiProfileMappingsDidResolve` carrying a
    /// `MappingsOutcome.rawValue`. Deliberately not the bare `"outcome"` that
    /// `.phiProfileAutoCreateDidRun` uses for its own, unrelated vocabulary.
    ///
    /// `nonisolated` because a notification observer is not main-actor isolated
    /// until it hops: an observer must be able to read the key to decide whether
    /// the hop is even worth making.
    nonisolated static let mappingsOutcomeKey = "mappingsOutcome"

    private(set) var resolved: [String: (uuid: String, passphrase: String)] = [:]
    /// The account and this Mac are not one-to-one yet: some local profile is
    /// undecided, OR some account profile has no local counterpart. After the
    /// second revision this is a NORMAL, brief state during auto-create -- it no
    /// longer means "interrupt the user".
    private(set) var needsPairing = false

    /// `needsPairing` minus the part no user could decide. Both of the modal's
    /// exits for an account profile whose envelope will not open under the
    /// current ARK throw inside `adoptRemoteProfile` -> `openProfilePayload`, so
    /// presenting it would lock the browser on a problem it cannot solve.
    private(set) var needsPairingActionable = false

    /// Account profile uuids whose envelope did not open under the current ARK.
    /// Two writers, each recording only what it knows: §3.6's per-round refresh,
    /// and `startPairing`'s `accountProfiles()` result (`name == nil`).
    private(set) var undecryptableRemoteUuids: Set<String> = []

    func noteUndecryptableRemote(_ uuid: String) { undecryptableRemoteUuids.insert(uuid) }
    func noteDecryptableRemote(_ uuid: String) { undecryptableRemoteUuids.remove(uuid) }

    /// Extra account defaults §3.6 has already demoted to ordinary profiles and
    /// logged (docs/sync.md, "Profile pairing and the default profile"), so the
    /// default-identity conflict is logged once per uuid, not every round.
    private var loggedDefaultConflictUuids: Set<String> = []

    /// Best-effort `"default"` flag backfill (docs/sync.md, "Profile pairing and
    /// the default profile"). Single-flight like the passes below. A uuid enters
    /// `confirmedDefaultFlagUuids` once its envelope is known to carry this Mac's
    /// flag, so later passes do not GET it every 60 s; the entry is keyed by
    /// profileId -> uuid, so a changed mapping re-checks. Failures are logged once
    /// per uuid and retried by the next pass.
    private(set) var defaultFlagBackfillTask: Task<Void, Never>?
    private var confirmedDefaultFlagUuids: [String: String] = [:]
    private var loggedDefaultFlagFailureUuids: Set<String> = []

    // MARK: - Profile mapping pause inputs (docs/sync.md, "Enrollment and setup")
    //
    // Read the way the two pairing predicates above are read: every write lands
    // before the `.phiProfileMappingsDidResolve` that announces it, so an observer
    // of that notification sees one consistent picture. `SyncProfileMappingPause`
    // turns them into a decision; nothing here pauses anything.

    /// The local Profiles whose mapping this controller knows to be absent on the
    /// server: a lookup found the envelope of their persisted mapping gone (404),
    /// or a MEASURED pass left them without a resolved account Profile. Evidence,
    /// not a per-pass answer: a held pass adds what it proved and erases nothing,
    /// so a 404 followed by a failed re-registration keeps pausing although the
    /// persisted mapping still exists. A Profile leaves only when a pass or an
    /// adopt resolves it, or when it no longer exists locally. `clearResolved()`
    /// keeps it while the account key is still available (a failed startup
    /// unlock proves nothing about the server's Profiles) and empties it once the
    /// key is gone or the controller is retired.
    private(set) var knownUnmappedProfileIds: Set<String> = []

    /// How the last pass ended: measured, held by a transient failure (a later
    /// pass can fix it), or refused definitively (the user has to act). Nil until
    /// a pass has run, and again after `clearResolved()`.
    private(set) var lastMappingsPassResult: SyncProfileMappingPassResult?

    /// Status-only category of the failure behind `lastMappingsPassResult`: nil
    /// when the last pass succeeded, before any pass, and after `clearResolved()`.
    /// Nothing decides anything on it; the pause's reason comes from the result.
    private(set) var lastMappingsFailureCategory: SyncProfileMappingFailureCategory?

    /// Local Profiles this controller created (§3.6's auto-create, the pairing
    /// wizard's "create local") and has not finished adopting. The pause ignores
    /// them until the adopt has finished or failed.
    private(set) var profileIdsBeingCreated: Set<String> = []

    /// The worst failure of the most recent auto-create round, nil when it failed
    /// nothing. A measured pass that still leaves a Profile unmapped reports it:
    /// an account Profile that auto-create could not claim is what keeps that
    /// Profile's registration waiting.
    private var lastAutoCreateFailure: SyncProfileMappingPassResult?
    private var lastAutoCreateFailureCategory: SyncProfileMappingFailureCategory?

    init(manager: AccountKeyManager, approvals: DeviceApprovalService, profileKeys: ProfileKeyManager,
         spaceKeys: SpaceSyncMappingManager? = nil,
         localProfilesProvider: @escaping () -> [(profileId: String, displayName: String)],
         notifyChromium: @escaping () -> Void,
         profileCreator: any LocalProfileCreating = ProfileManager.shared,
         isPairingComplete: @escaping @MainActor () -> Bool = { ProfilePairingGate.shared.isPaired },
         isProfileListEnumerated: @escaping @MainActor () -> Bool = { true },
         profileEntityView: (@MainActor () -> AccountProfileEntityView?)? = nil,
         retirePhiSync: @escaping (Bool) -> Void = { _ in },
         invalidateEnrollment: @escaping () throws -> Void = {},
         deviceKeyRotator: (any DeviceKeyRotating)? = nil,
         engineDefaults: UserDefaults = .standard,
         spaceStateStore: (any PhiSpaceSyncStateStore)? = nil,
         ownedItemStores: [any PhiOwnedItemStateStore] = [],
         markerStore: (any PhiSyncMarkerStore)? = nil,
         clearAllSyncIds: (@Sendable () async throws -> Void)? = nil,
         finishLocalCleanup: @escaping (Bool) -> Void = { _ in },
         verifyCursorDeletion: @escaping () throws -> Void = {},
         isCurrentAccount: @escaping () -> Bool = { true },
         runtimeRequiresReconfiguration: @escaping () -> Bool = { false },
         runtimeRemovalPending: @escaping () -> Bool = { false },
         localResetMarker: SyncPairingLocalResetMarkerStore? = nil,
         localResetAccess: PhiLocalDataReset.LocalAccess? = nil,
         profileDeletionIntents: @escaping @MainActor () -> (any PhiProfileDeletionIntentStore)? = {
             PhiSpaceSyncState.shared.profileDeletionIntentStore
         },
         unlockRetryDelay: @escaping (Int) -> Duration = SyncKeyController.defaultUnlockRetryDelay) {
        self.isPairingComplete = isPairingComplete
        self.unlockRetryDelay = unlockRetryDelay
        self.isProfileListEnumerated = isProfileListEnumerated
        self.profileEntityView = profileEntityView
        self.manager = manager
        self.approvals = approvals
        self.profileKeys = profileKeys
        self.spaceKeys = spaceKeys
        self.localProfilesProvider = localProfilesProvider
        self.notifyChromium = notifyChromium
        self.profileCreator = profileCreator
        self.retirePhiSync = retirePhiSync
        self.invalidateEnrollment = invalidateEnrollment
        self.finishLocalCleanup = finishLocalCleanup
        self.verifyCursorDeletion = verifyCursorDeletion
        self.isCurrentAccount = isCurrentAccount
        self.runtimeRequiresReconfiguration = runtimeRequiresReconfiguration
        self.runtimeRemovalPending = runtimeRemovalPending
        self.deviceKeyRotator = deviceKeyRotator
        self.engineDefaults = engineDefaults
        self.spaceStateStore = spaceStateStore
        self.ownedItemStores = ownedItemStores
        self.markerStore = markerStore
        self.clearAllSyncIds = clearAllSyncIds
        self.localResetMarker = localResetMarker
        self.localResetAccess = localResetAccess
        self.profileDeletionIntents = profileDeletionIntents
    }

    /// While true, `profileSyncInfo` answers nil for every Profile; setting it
    /// back hands out the same values again, because resolution and the cache
    /// carry on underneath. Withdrawing a key stops a Chromium engine without
    /// clearing its metadata (docs/sync.md, "Chromium account and key
    /// lifecycle"). Plain state: its owner decides when to set it and pings
    /// Chromium itself.
    var chromiumKeysWithdrawn = false

    /// Local Profiles being deleted (docs/sync.md, "Chromium account and key lifecycle"). Their key
    /// is withdrawn and a mapping pass neither resolves nor registers them, so a deleted Profile's
    /// basename cannot keep or regain a key and its absence never reads as "unmapped".
    private(set) var profileIdsBeingDeleted: Set<String> = []
    /// Mapping pass sequence: incremented as each pass starts. A withdrawal records the current
    /// value, so a pass that was already running when the key was withdrawn (its start is not
    /// later than the withdrawal) cannot put the key back, even when the deletion finished and
    /// left `profileIdsBeingDeleted` before the pass resumed.
    private var passSequence: UInt64 = 0
    private var withdrawnAtPass: [String: UInt64] = [:]
    /// Every account Profile uuid the key registry listed at its last successful read. The registry
    /// never forgets a uuid, so the sync engine resolves any Profile tombstone's tag from it
    /// (docs/sync.md, "Profile entity"). Empty until the first read this process.
    private(set) var lastAccountProfileUuids: Set<String> = []

    /// Stops Chromium sync for one Profile before it is deleted.
    func withdrawProfileKey(profileId: String) {
        profileIdsBeingDeleted.insert(profileId)
        withdrawnAtPass[profileId] = passSequence
        if resolved.removeValue(forKey: profileId) != nil { notifyChromium() }
    }

    /// The deletion failed: the Profile stays, so the next pass resolves its key again.
    func restoreProfileKey(profileId: String) {
        guard profileIdsBeingDeleted.remove(profileId) != nil else { return }
        withdrawnAtPass[profileId] = nil
        Task { @MainActor [weak self] in await self?.resolveMappings() }
    }

    /// The deletion committed; the Profile is gone from the local list. `withdrawnAtPass` keeps
    /// the entry until a pass prunes it, so a pass that was suspended meanwhile cannot restore it.
    func finishProfileKeyWithdrawal(profileId: String) {
        profileIdsBeingDeleted.remove(profileId)
    }

    /// Local Profiles the pairing reset deletes (docs/sync.md, "Replacing this Mac's data at
    /// pairing"), keyed by the pass sequence when the reset named them. Such a Profile is unmapped,
    /// so `withdrawProfileKey` never sees it, yet a pass must neither register nor twin it: a pass
    /// reads the Profile list once, before its network calls, and checks the pairing gate after
    /// them, so a pass that read the list before the deletion resumes after enrollment opened the
    /// gate and still names the deleted Profile (acceptance SYNC-P22, 2026-10-20). An entry leaves
    /// only when a pass that started after the reset named it reads an enumerated list without the
    /// Profile; passes run one at a time, so no pass that could still name it is running then.
    private var registrationExcludedAtPass: [String: UInt64] = [:]

    /// The Profiles `excludeFromRegistration` named that no pass has seen gone yet.
    var registrationExcludedProfileIds: Set<String> { Set(registrationExcludedAtPass.keys) }

    /// Called by the pairing reset before it deletes `profileId`.
    func excludeFromRegistration(profileId: String) {
        registrationExcludedAtPass[profileId] = passSequence
    }

    private func isExcludedFromRegistration(_ profileId: String) -> Bool {
        registrationExcludedAtPass[profileId] != nil
    }

    /// Hot path: the bridge delegate calls this on every Chromium pull.
    /// Dictionary read only — no I/O, no crypto.
    func profileSyncInfo(forProfileId profileId: String) -> (uuid: String, passphrase: String)? {
        guard isPairingComplete(), !chromiumKeysWithdrawn else { return nil }
        return resolved[profileId]
    }

    /// Local profiles as reported by `localProfilesProvider` — the same
    /// enumeration `resolveMappings()` uses internally. Exposed read-only for
    /// the pairing UI (M2-4 Task 5), which needs to list every local profile
    /// alongside the account's remote profiles when `needsPairing` is true.
    func localProfiles() -> [(profileId: String, displayName: String)] {
        localProfilesProvider()
    }

    /// Main-actor face of `ProfileKeyManager.localProfileId(forGlobalUuid:)` for
    /// the Space engine, which reaches the key layer only through a main-thread hop.
    func localProfileId(forGlobalUuid uuid: String) -> String? {
        profileKeys.localProfileId(forGlobalUuid: uuid)
    }

    /// §6.2 A0 / §3.6's single self-heal path: the local profile behind this
    /// mapping no longer exists, so the entry has to go or the reverse lookup
    /// keeps handing the Space engine a `profileId` that every landing throws on.
    /// Dropping it puts the uuid back into §3.6's `missing` next round.
    func removeMapping(forProfileId profileId: String) {
        profileKeys.removeMapping(forProfileId: profileId)
    }

    // MARK: - Space sync identity (M3-2b §2.2)

    /// Main-actor facade matching localProfileId(forGlobalUuid:). AccountPhiSpaceAccess uses its existing
    /// controller reference for Space mappings; the engine reaches this only through PhiSpaceLocalAccess, with
    /// no new dependency.
    func syncUuid(forSpaceId spaceId: String) -> String? {
        spaceKeys?.syncUuid(forSpaceId: spaceId)
    }

    func localSpaceId(forSyncUuid uuid: String) -> String? {
        spaceKeys?.localSpaceId(forSyncUuid: uuid)
    }

    @discardableResult
    func ensureSpaceMapped(spaceId: String) throws -> String {
        guard let spaceKeys else { throw SpaceSyncMappingError.mappingLayerUnavailable }
        return try spaceKeys.ensureMapped(spaceId: spaceId)
    }

    func mapSpace(_ spaceId: String, toSyncUuid uuid: String, replacing expectedUuid: String? = nil) throws {
        guard let spaceKeys else { throw SpaceSyncMappingError.mappingLayerUnavailable }
        try spaceKeys.map(spaceId: spaceId, toSyncUuid: uuid, replacing: expectedUuid)
    }

    func removeSpaceMapping(forSpaceId spaceId: String) {
        spaceKeys?.removeMapping(forSpaceId: spaceId)
    }

    func allSpaceMappings() -> [String: String] {
        spaceKeys?.allMappings() ?? [:]
    }

    // MARK: - Replacing this Mac's data at pairing (docs/sync.md, "Enrollment and setup")

    /// The resume marker for this device key, or nil.
    func pairingLocalResetMarker() -> SyncPairingLocalResetMarker? {
        guard let deviceKeyId = try? manager.deviceKeyProviderForTesting.deviceKeyId() else { return nil }
        return localResetMarker?.load(deviceKeyID: deviceKeyId)
    }

    /// Records that the reset is starting, before anything local is removed.
    func savePairingLocalResetMarker(deleteProfileIds: Set<String>,
                                     startedAt: Date = Date()) throws {
        guard let localResetMarker else { throw SyncPairingLocalResetMarkerError.writeFailed }
        let deviceKeyId = try manager.deviceKeyProviderForTesting.deviceKeyId()
        try localResetMarker.save(SyncPairingLocalResetMarker(
            deviceKeyID: deviceKeyId, deleteProfileIds: deleteProfileIds,
            startedAtMs: Int64((startedAt.timeIntervalSince1970 * 1000).rounded())))
    }

    /// The local data reset bound to this controller's sync state, or nil when this controller was
    /// built without the stores the preconditions read (tests, unwired construction): without them
    /// the reset could not prove that nothing it deletes reaches the account.
    func localDataReset() -> PhiLocalDataReset? {
        guard let localResetAccess, let spaceStateStore, let markerStore else { return nil }
        let ownedItemStores = ownedItemStores
        let profileDeletionIntents = profileDeletionIntents
        return PhiLocalDataReset(sync: PhiLocalDataReset.SyncAccess(
            isPaired: { [weak self] in self?.isPairingComplete() ?? true },
            // A removal or account reset in flight (`cleaningLocalState`) is not a usable
            // session: this Mac is leaving the account, so the pairing reset must not start.
            isSessionUsable: { [weak self] in
                guard let self else { return false }
                return !self.isRetired && !self.cleaningLocalState && self.manager.currentARK != nil
                    && !self.requiresReconfiguration && self.isCurrentAccount()
            },
            syncHistory: {
                var history: [PhiLocalDataReset.SyncHistory] = []
                let table = spaceStateStore.load()
                if table.cursors.values.contains(where: { $0.entityId?.isEmpty == false }) {
                    history.append(.spaceCursor)
                }
                if table.profileCursors.values.contains(where: { $0.entityId?.isEmpty == false }) {
                    history.append(.profileCursor)
                }
                let marker = markerStore.load()
                if marker.marker != nil || !marker.storeBirthday.isEmpty { history.append(.marker) }
                if ownedItemStores.contains(where: { store in
                    store.load(hadRecords: table.hadRecords).table.cursors.values
                        .contains { !$0.entityId.isEmpty || $0.reconciled != nil }
                }) {
                    history.append(.ownedItemCursor)
                }
                // No journal store means the journal cannot be read: fail closed.
                if profileDeletionIntents()?.load().isEmpty != true {
                    history.append(.profileDeletionJournal)
                }
                return history
            },
            isProfileMapped: { [weak self] in self?.profileKeys.mappedGlobalUuid(forProfileId: $0) != nil },
            spaceMappings: { [weak self] in self?.allSpaceMappings() ?? [:] },
            removeSpaceMapping: { [weak self] in self?.removeSpaceMapping(forSpaceId: $0) },
            clearSettingsAdoption: { [weak self] in
                guard let self, self.isCurrentAccount() else { return }
                Self.clearSettingsAdoptionState(self.engineDefaults)
            },
            excludeFromRegistration: { [weak self] in self?.excludeFromRegistration(profileId: $0) }),
            local: localResetAccess)
    }

    /// User-confirmed removal revokes remotely before touching local sync metadata.
    /// Last-device and transport errors leave local data and enrollment unchanged.
    func removeThisDeviceFromSync() async throws {
        guard !isRetired, !cleaningLocalState else { throw CancellationError() }
        cleaningLocalState = true
        defer { cleaningLocalState = false }
        let deviceKeyId = try manager.deviceKeyProviderForTesting.deviceKeyId()
        try await profileKeys.revokeDevice(deviceKeyId: deviceKeyId)
        guard !isRetired, isCurrentAccount() else { throw CancellationError() }
        try await clearLocalSyncState(removingDevice: true)
    }

    /// The account reset, offered only after `removeThisDeviceFromSync()` was refused with
    /// `last_device` and the user confirmed a second time. Server first, like self-revoke:
    /// the operation UUID is journaled, the server deletes the account's sync data, and
    /// only then does the shared cleanup run. A refusal (`notLastDevice`, `deviceNotFound`)
    /// deleted nothing, so local state stays and the journal forgets the operation; any
    /// other failure keeps the UUID so the next attempt retries the same operation.
    ///
    /// The journaled UUID is the durable "unfinished" mark: from the moment it is written,
    /// `requiresReconfiguration` is true. After a lost response or a crash, a relaunched
    /// Mac (envelope gone, so `.needsJoin`, no ARK, no engine round) therefore offers Set up
    /// sync again, which resumes the operation, and the setup window refuses to start.
    func resetSyncAndRemoveThisDevice() async throws {
        guard !isRetired, !cleaningLocalState else { throw CancellationError() }
        cleaningLocalState = true
        defer { cleaningLocalState = false }
        let deviceKeyId = try manager.deviceKeyProviderForTesting.deviceKeyId()
        let operationId = markerStore?.load().resetOperationId ?? UUID()
        try journalResetOperation(operationId)
        try await requestAccountReset(operationId: operationId, deviceKeyId: deviceKeyId)
        guard !isRetired, isCurrentAccount() else { throw CancellationError() }
        try await clearLocalSyncState(removingDevice: true)
    }

    /// Called only after explicit reconfiguration confirmation. Ordinary setup/retry
    /// never calls this method. A partial removal also resumes through this path, and so
    /// does an account reset whose outcome this Mac never recorded (a lost response, or a
    /// crash between the server's answer and the end of cleanup): the journaled operation
    /// is retried first with the same UUID. The server answers a finished reset with
    /// `reset` again, and a refusal turns this back into an ordinary reconfiguration.
    /// A journaled UUID alone is enough to get here (see `requiresReconfiguration`); the
    /// resume needs only the token and the device key id, not the account key.
    func reconfigureSync() async throws {
        guard !isRetired, !cleaningLocalState, isCurrentAccount(), requiresReconfiguration else {
            throw CancellationError()
        }
        cleaningLocalState = true
        defer { cleaningLocalState = false }
        var removingDevice = markerStore?.load().removalPending == true || runtimeRemovalPending()
        if let operationId = markerStore?.load().resetOperationId {
            do {
                let deviceKeyId = try manager.deviceKeyProviderForTesting.deviceKeyId()
                try await requestAccountReset(operationId: operationId, deviceKeyId: deviceKeyId)
                removingDevice = true
            } catch KeyAPIError.notLastDevice, KeyAPIError.deviceNotFound {
                AppLogInfo("[phi-sync] pending account reset was refused; reconfiguring without it")
            }
            guard !isRetired, isCurrentAccount() else { throw CancellationError() }
        }
        try await clearLocalSyncState(removingDevice: removingDevice)
    }

    /// Records the reset's operation UUID before the request goes out. Nil `markerStore`
    /// is unwired/test construction, which has no journal to write.
    /// The write goes through `update`, because the engine may save the same file meanwhile.
    private func journalResetOperation(_ operationId: UUID) throws {
        guard let markerStore else { return }
        guard markerStore.load().resetOperationId != operationId else { return }
        guard markerStore.update({ $0.resetOperationId = operationId }) else {
            throw NativeSyncResetError.cleanupFailed
        }
    }

    /// Sends the journaled reset. The server's two refusals deleted nothing, so the journal
    /// forgets the operation before the refusal propagates; every other error leaves it.
    private func requestAccountReset(operationId: UUID, deviceKeyId: String) async throws {
        do {
            try await profileKeys.resetAccount(operationId: operationId, deviceKeyId: deviceKeyId)
            AppLogInfo("[phi-sync] account reset accepted by the server")
        } catch let error as KeyAPIError {
            switch error {
            case .notLastDevice, .deviceNotFound: break
            default: throw error
            }
            AppLogInfo("[phi-sync] account reset refused (\(PhiSyncLog.describe(error)))")
            // A failed save leaves a UUID the server will refuse again; nothing depends on it.
            markerStore?.update { $0.resetOperationId = nil }
            throw error
        }
    }

    private func clearLocalSyncState(removingDevice: Bool) async throws {
        // Stop in-flight writers before touching even the journal. The coordinator
        // retains the pending intent in memory if this first durable write fails.
        retirePhiSync(removingDevice)
        var completed = false
        defer { finishLocalCleanup(completed) }
        // Keep the account-scoped marker as a cleanup journal until every other
        // step succeeds. Its original birthday and progress token remain intact.
        if let markerStore {
            let journaled = markerStore.update { journal in
                journal.requiresReconfiguration = true
                journal.removalPending = removingDevice
            }
            guard journaled else { throw NativeSyncResetError.cleanupFailed }
        }
        try invalidateEnrollment()
        // A pairing reset in progress belongs to the enrollment just invalidated.
        guard localResetMarker?.clear() != false else { throw NativeSyncResetError.cleanupFailed }
        try manager.discardLocalRegistration()
        clearResolved()
        if removingDevice { try deviceKeyRotator?.rotateForCurrentAccount() }

        profileKeys.removeAllMappings()
        spaceKeys?.removeAllMappings()
        guard profileKeys.allMappings().isEmpty, spaceKeys?.allMappings().isEmpty != false else {
            throw NativeSyncResetError.cleanupFailed
        }
        // Delete cursor files before clearing bookmark sync IDs. Rule identity and
        // pin lineage are business identities and survive; browsing rows stay intact.
        for store in ownedItemStores { store.deleteFile() }
        try verifyCursorDeletion()
        try await clearAllSyncIds?()
        // The async storage write belongs to the captured account. Never clear the
        // next account's global engine defaults or facade after an account switch.
        guard isCurrentAccount() else { throw CancellationError() }
        Self.clearSettingsAdoptionState(engineDefaults, alsoRemoving: PhiSyncEngine.legacyMarkerStateKeys
                                            + ["phi.sync.requiresReconfiguration"])
        // This mirrored value is a sync UUID, not the user's local default Space.
        engineDefaults.removeObject(forKey: PhiDefaultSpaceMirror.key)
        if let spaceStateStore, !spaceStateStore.save(PhiSpaceSyncTable()) {
            throw NativeSyncResetError.cleanupFailed
        }
        PhiSpaceSyncState.shared.refreshCaches(from: PhiSpaceSyncTable())
        // The Profile deletion journal describes the cursors just cleared.
        if let intents = PhiSpaceSyncState.shared.profileDeletionIntentStore, !intents.save([:]) {
            throw NativeSyncResetError.cleanupFailed
        }
        markerStore?.deleteFile()
        guard markerStore?.load().requiresReconfiguration != true else {
            throw NativeSyncResetError.cleanupFailed
        }
        completed = true
        AppLogInfo("[phi-sync] confirmed local sync cleanup completed")
    }

    /// Drops the settings engine's account cursor (`stateKeys`, `hasAdopted` included) and every
    /// per-key timestamp/value sidecar, keeping the settings' values. The next pull then adopts
    /// the account's settings wholesale. Shared by the confirmed cleanup above and the pairing
    /// reset (docs/sync.md, "Replacing this Mac's data at pairing"). Idempotent.
    static func clearSettingsAdoptionState(_ defaults: UserDefaults, alsoRemoving extraKeys: [String] = []) {
        for key in PhiSyncEngine.stateKeys + extraKeys {
            defaults.removeObject(forKey: key)
        }
        for key in defaults.dictionaryRepresentation().keys
            where key.hasSuffix(SyncableSettings.timestampSuffix) || key.hasSuffix(SyncableSettings.valueSuffix) {
            defaults.removeObject(forKey: key)
        }
    }

    /// Startup/login entry: unlock without UI, then resolve mappings and ping.
    /// The Profile-list follow-up enters here too. `.needsJoin` / `.notSignedIn`
    /// leave the cache empty — the Devices pane remains the place where
    /// joining/bootstrap UI happens.
    ///
    /// While the ARK is NOT held, any outcome other than `.unlocked` (including
    /// a thrown, possibly transient, failure) CLEARS the cache rather than
    /// leaving it standing: the unknown state fails *closed* (Chromium pulls nil
    /// and the sync gate shuts), and the first successful unlock announces
    /// `.phiAccountKeyDidUnlock`, so a later trigger retries. A thrown failure
    /// in that state also schedules its own retry (`scheduleUnlockRetry`): the
    /// only other triggers are the launch-time login refresh and a Profile-list
    /// change, so a launch with the key service unreachable otherwise stayed
    /// locked after the connection returned (every round `gated`, every Chromium
    /// Profile `notUnlocked`, Sync Now refused; PR #181 acceptance, 2026-10-12).
    ///
    /// Once the ARK is held that retry no longer exists (the notification fires
    /// only on the nil -> unlocked transition), so a transient failure would
    /// withdraw the keys until the next Profile-list change. A throw (offline,
    /// timeout, 5xx, Keychain) or a 401 (`.notSignedIn`: sign-out retires the
    /// controller, so a live one has a token blip) therefore keeps the cache and
    /// runs `resolveMappings()`, which holds rather than clears on its own
    /// transient failures. Only `.needsJoin` still clears: a 404 with no parked
    /// registration is the definitive answer that this device's envelope is gone
    /// (remote revocation, server reset).
    ///
    /// Single-flight, like `resolveMappings()`: see `silentUnlockTask`.
    func silentUnlockAndResolve() async {
        guard !isRetired else { return }
        silentUnlockPending = true
        if let running = silentUnlockTask {
            // One more pass after the current one, then return with every other
            // waiter: the startup caller starts sync after this await, so it must
            // mean "a pass that saw my state has finished".
            await running.value
            return
        }
        let task = Task { @MainActor [weak self] in
            while let self, self.silentUnlockPending {
                self.silentUnlockPending = false
                await self.silentUnlockAndResolveOnce()
            }
            // No suspension between the loop's last check and this write (see
            // `resolveMappings()`).
            self?.silentUnlockTask = nil
        }
        silentUnlockTask = task
        await task.value
    }

    private func silentUnlockAndResolveOnce() async {
        guard !isRetired else { return }
        let result: UnlockResult
        do {
            result = try await manager.unlockAtStartup()
        } catch {
            // The unlock is an `await`; the account may have gone away inside it (review A11).
            guard !isRetired else { return }
            guard manager.currentARK != nil else {
                clearResolved()  // transient (offline etc.) — fails closed until the retry below unlocks
                scheduleUnlockRetry(after: error)
                return
            }
            AppLogWarn("[phi-sync] silent unlock failed with the account key held; keeping resolved keys (\(PhiSyncLog.describe(error)))")
            await resolveMappings()
            return
        }
        guard !isRetired else { return }
        // Any answer from the key service settles the retry: `.unlocked` is what it waited
        // for, and `.needsJoin` / `.notSignedIn` are definitive (a join or a sign-in re-enters
        // here through the pane and the login notifications).
        cancelUnlockRetry()
        switch result {
        case .unlocked:
            break
        case .needsJoin:
            // The only branch that withdraws keys while the account key is held, so it
            // leaves a trace: nothing in `clearResolved()` logs (acceptance 2026-10-10).
            if manager.currentARK != nil {
                AppLogWarn("[phi-sync] silent unlock found no envelope for this device; withdrawing resolved keys")
            }
            clearResolved()
            return
        case .notSignedIn:
            guard manager.currentARK != nil else {
                clearResolved()
                return
            }
            AppLogWarn("[phi-sync] silent unlock got 401 with the account key held; keeping resolved keys")
        }
        await resolveMappings()
    }

    /// Runs a silent unlock now when the account key is not held: Sync Now on a
    /// launch whose unlock failed is the user asking for exactly that, and the
    /// coordinator refuses the request itself while the key is missing. A pending
    /// retry is replaced, not doubled; with the key held this is a no-op.
    func kickSilentUnlockIfLocked() {
        guard !isRetired, manager.currentARK == nil else { return }
        cancelUnlockRetry()
        Task { @MainActor [weak self] in await self?.silentUnlockAndResolve() }
    }

    /// Arms one retry of the silent unlock after a thrown failure without the
    /// account key. The pass that it runs lands back in `silentUnlockAndResolveOnce`,
    /// which re-arms on the next throw (with a longer wait) or settles on any
    /// answer. One timer at a time: a second failure while one is pending (the
    /// Profile-list follow-up can fail the same way) keeps the earlier, shorter wait.
    private func scheduleUnlockRetry(after error: Error) {
        guard unlockRetryTask == nil else { return }
        let attempt = unlockRetryAttempt
        unlockRetryAttempt += 1
        let delay = unlockRetryDelay(attempt)
        AppLogWarn("[phi-sync] silent unlock failed without the account key; retrying in \(delay.components.seconds)s (\(PhiSyncLog.describe(error)))")
        unlockRetryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled, !self.isRetired else { return }
            self.unlockRetryTask = nil
            // Another flow may have supplied the key meanwhile. Still complete this
            // recovery pass: holding the account key alone does not publish Profile keys.
            await self.silentUnlockAndResolve()
        }
    }

    /// Drops every cached key and pings Chromium if there was anything to drop,
    /// so a locked / signed-out / account-switched controller stops serving the
    /// previous session's passphrases across the bridge.
    ///
    /// It ANNOUNCES, because it is the other writer of both pairing predicates:
    /// a lock or sign-out taken while the app-modal pairing gate is up flips them
    /// false here with no pass to follow (`silentUnlockAndResolve` returns
    /// straight after its clearing branches), and the gate dismisses only from
    /// `.phiProfileMappingsDidResolve`. Staying silent would leave the browser
    /// blocked behind a modal with nothing left to pair.
    ///
    /// `knownUnmappedProfileIds` survives it while the account key is still
    /// available: a startup unlock that failed says nothing about which mappings
    /// are gone on the server.
    ///
    /// It announces as `.cleared`, NOT like a measured pass: the false predicates
    /// below say "unknown", so the gate may take its window down but must not
    /// read them as "this join finished" and retire `sync.joinPairingPending`.
    /// The common case is the exact opposite of finished -- a relaunch seconds
    /// after a join, offline, where `unlockAtStartup()` throws before any pass
    /// has ever run.
    func clearResolved() {
        let wasPopulated = !resolved.isEmpty
        resolved = [:]
        needsPairing = false
        needsPairingActionable = false
        if isRetired || manager.currentARK == nil { knownUnmappedProfileIds = [] }
        lastMappingsPassResult = nil
        lastMappingsFailureCategory = nil
        if wasPopulated { notifyChromium() }
        announceMappingsResolved(.cleared)
    }

    /// Set by `retire()` and never cleared: the account this controller was built for is gone
    /// (sign-out, account switch, self-revocation). A pass that was parked in a network call
    /// when that happened resumes on the next account's bearer token — its API client reads
    /// the token from the global `AuthManager` on every request — and would register every
    /// unmapped local Profile into the NEW account, sealed with the OLD account's ARK
    /// (review A11). Every write in a pass is gated on this after each suspension.
    private(set) var isRetired = false

    /// The teardown entry (review A11): clears the cache like `clearResolved()`, cancels the
    /// running pass and auto-create round, and marks the controller so a pass or round that
    /// cannot be cancelled mid-request still writes nothing once it resumes.
    func retire() {
        isRetired = true
        resolveTask?.cancel()
        silentUnlockTask?.cancel()
        cancelUnlockRetry()
        autoCreateTask?.cancel()
        defaultFlagBackfillTask?.cancel()
        clearResolved()
    }

    /// 5 s doubling to 60 s: the key-service lookup is one GET, and nothing
    /// observes the connection coming back (the repair loop in
    /// `SyncProfileMappingPauseReconciler` caps its offline wait the same way).
    static func defaultUnlockRetryDelay(attempt: Int) -> Duration {
        .seconds(min(5 << min(attempt, 4), 60))
    }

    private func cancelUnlockRetry() {
        unlockRetryTask?.cancel()
        unlockRetryTask = nil
        unlockRetryAttempt = 0
    }

    /// Re-runs resolution after external events (pairing applied, approval
    /// completed, bootstrap finished in the Devices pane).
    ///
    /// Error taxonomy (C-1). A local profile's lookup has three outcomes, and
    /// conflating the last two is what caused the silent re-registration bug:
    ///
    /// - record returned  -> mapped and readable; cache it.
    /// - nil returned     -> definitively unmapped (no mapping stored, or the
    ///                       mapping's remote is gone / 404). Eligible for the
    ///                       register / adopt decision below.
    /// - throws           -> UNKNOWN, not absent (offline, 5xx, 401, still
    ///                       locked). Keep whatever was previously resolved and
    ///                       hold this local out of the decision entirely.
    ///
    /// A single unknown local also poisons the *decision* for every other
    /// local: its remote UUID cannot be counted as claimed, so an unrelated
    /// unmapped local could auto-adopt the envelope that actually belongs to
    /// it. So when any local is unknown, the whole register/adopt/pairing
    /// decision is skipped this pass and retried on the next trigger. Likewise
    /// a failed account listing skips the register/adopt decision and HOLDS both
    /// pairing predicates — the branches below are only sound with a fully known
    /// remote set, and an app-modal gate must never be flipped true by a blip.
    ///
    /// Both of those bail-outs still announce, but as `.held`: they hold values
    /// this pass did not measure (on a fresh controller, the initial `false`),
    /// and a consumer must no more read them as an answer than it reads
    /// `clearResolved()`'s. Only the branch that ASSIGNS the two predicates
    /// announces `.measured`.
    ///
    /// Registration failures are classified, never swallowed. A
    /// transient one (transport, offline, 5xx, 401/403, still locked)
    /// holds the pass exactly like an unknown local: the Profile it could not
    /// register must not read as "measured, unmapped", which is an answer. A
    /// definitive one (bad envelope, an unexpected 4xx) still measures, and
    /// `lastMappingsPassResult` says so.
    func resolveMappings() async {
        resolvePending = true
        if let running = resolveTask {
            // One more pass after the current one, then return with every
            // other waiter: a caller must never observe "my state change was
            // not looked at" -- and must never run a second pass beside it.
            await running.value
            return
        }
        let task = Task { @MainActor [weak self] in
            while let self, self.resolvePending {
                self.resolvePending = false
                await self.resolveMappingsOnce()
            }
            // No suspension between the loop's last check and this write, so a
            // caller can only arrive before it (and be served by the loop) or
            // after it (and start the next task).
            self?.resolveTask = nil
        }
        resolveTask = task
        await task.value
    }

    /// Single-flight state for `resolveMappings()`. The pass is re-entered from
    /// several triggers at once on a fresh device -- the login unlock,
    /// `.phiAccountKeyDidUnlock`, and the `$profiles` sink, which since T17 F1
    /// fires INSIDE a pass (`localProfilesProvider` refreshes the Chromium list,
    /// and the first population changes it). Two passes interleaving at their
    /// awaits each saw "Default" unmapped over an empty account and each
    /// registered it: the account got two profiles named "Your Phi", the second
    /// pass overwrote the mapping, and §3.6 then created "Your Phi (2)" for the
    /// orphaned first uuid (T17 run 4, 2026-09-11). `registerLocalProfile`'s
    /// `alreadyMapped` refusal cannot catch this: both passes check it before
    /// either has written. So: one pass at a time, later callers coalesce into
    /// exactly one follow-up pass.
    private var resolveTask: Task<Void, Never>?
    private var resolvePending = false

    /// Removes the keys of Profiles being deleted, and of every Profile withdrawn during or after
    /// the pass that started at `passStartedAt`, from the resolved cache after a pass merged its result.
    private func dropWithdrawnKeys(passStartedAt: UInt64) {
        for profileId in profileIdsBeingDeleted { resolved[profileId] = nil }
        for (profileId, seq) in withdrawnAtPass where seq >= passStartedAt { resolved[profileId] = nil }
    }

    /// Single-flight state for `silentUnlockAndResolve()`. It is entered from the
    /// startup/login unlock and from the Profile-list follow-up, and the two can
    /// overlap: one pass resolved the keys, then the other's device-envelope
    /// lookup failed (an offline blip, a 45 s request timeout) and its
    /// `clearResolved()` wiped what the first had just resolved, so Chromium
    /// pulled nil and sync silently stopped (BH-52). So: one unlock pass at a
    /// time, later callers coalesce into exactly one follow-up pass.
    private var silentUnlockTask: Task<Void, Never>?
    private var silentUnlockPending = false

    /// The pending retry of a silent unlock that threw without the account key
    /// (`scheduleUnlockRetry`), and how many such retries this locked stretch has
    /// used; both reset when a pass gets any answer. The delay is injected so
    /// tests do not wait.
    private var unlockRetryTask: Task<Void, Never>?
    private var unlockRetryAttempt = 0
    private var unlockRetryDelay: (Int) -> Duration = SyncKeyController.defaultUnlockRetryDelay

    private func resolveMappingsOnce() async {
        guard !isRetired else { return }
        var next: [String: (uuid: String, passphrase: String)] = [:]
        let previousStart = passSequence
        passSequence += 1
        let startedAt = passSequence
        let allLocals = localProfilesProvider()
        // A finished withdrawal older than one full pass whose basename no local Profile names any
        // more is forgotten; a new Profile that reuses the basename then resolves normally.
        let localIds = Set(allLocals.map(\.profileId))
        withdrawnAtPass = withdrawnAtPass.filter { id, seq in
            seq >= previousStart || localIds.contains(id) || profileIdsBeingDeleted.contains(id)
        }
        // Every exclusion was recorded before this pass started (passes are single-flight), so a
        // Profile it names that this list no longer holds is gone. An unread list proves nothing.
        if isProfileListEnumerated() {
            registrationExcludedAtPass = registrationExcludedAtPass.filter { id, seq in
                seq >= startedAt || localIds.contains(id)
            }
        }
        let locals = allLocals.filter {
            !profileIdsBeingDeleted.contains($0.profileId) && !isExcludedFromRegistration($0.profileId)
        }
        var unmappedLocals: [(profileId: String, displayName: String)] = []
        var hasUnknownLocal = false
        // Every failure this pass met, by class (BH-15). Any transient one holds
        // the pass; the worst one becomes `lastMappingsPassResult`.
        var failures: Set<SyncProfileMappingPassResult> = []
        // The status-only category of the latest failure this pass met.
        var failureCategory: SyncProfileMappingFailureCategory?
        // Evidence for `knownUnmappedProfileIds`, applied only after the retirement
        // checks below: Profiles this pass resolved, and Profiles whose persisted
        // mapping it found gone on the server.
        var resolvedNow: Set<String> = []
        var provenAbsent: Set<String> = []
        for local in locals {
            do {
                let record = try await profileKeys.resolvedRecord(forLocalProfile: local.profileId)
                guard !isRetired else { return }
                if let rec = record {
                    next[local.profileId] = (rec.uuid, rec.passphrase)
                    resolvedNow.insert(local.profileId)
                    probeResolve("existing", profileId: local.profileId, uuid: rec.uuid, passphrase: rec.passphrase)
                } else {
                    // A non-nil priorMapping here means the local is mapped to a UUID
                    // whose server envelope is gone (404) — the stale-mapping wedge that
                    // then trips `alreadyMapped` on re-register. Surface it explicitly.
                    // R12: an account-global `profile_uuid` never goes into the
                    // file log in full -- 8 characters are enough to correlate
                    // two lines within one bundle.
                    let priorMapping = profileKeys.mappedGlobalUuid(forProfileId: local.profileId)
                    AppLogInfo("[phi-sync-probe] unmapped profile=\(local.profileId) priorMapping=\(priorMapping.map { String($0.prefix(8)) } ?? "none")")
                    if priorMapping != nil { provenAbsent.insert(local.profileId) }
                    unmappedLocals.append(local)
                }
            } catch {
                guard !isRetired else { return }
                hasUnknownLocal = true
                let failure = Self.mappingFailureResult(for: error)
                failures.insert(failure)
                failureCategory = Self.mappingFailureCategory(for: error)
                AppLogInfo("[phi-sync-probe] unknown(\(failure.rawValue)) profile=\(local.profileId) (\(PhiSyncLog.describe(error)))")
                if let previous = resolved[local.profileId] { next[local.profileId] = previous }
            }
        }

        // The remote SET is fetched on EVERY pass now, including the one where
        // every local is already mapped -- that is exactly the case the second
        // disjunct of the new predicate is about ("the account has a profile this
        // Mac does not"). `accountProfileUuids()` and not `accountProfiles()`:
        // nothing here ever reads a display name, and the latter pays one
        // envelope GET per uuid, every 60 s.
        let remoteUuids: Set<String>
        do {
            remoteUuids = try await profileKeys.accountProfileUuids()
            // Review A11: the listing may have answered for the NEXT account; write nothing.
            guard !isRetired else { return }
            lastAccountProfileUuids = remoteUuids
        } catch {
            guard !isRetired else { return }
            // Unknown remote set (offline / 5xx / 401 / still locked). Hold the
            // previous answer -- NEVER flip an app-modal gate true on a blip --
            // and still announce, or the gate and the Space gate miss a state
            // update until the next trigger. `.held`, because the predicates that
            // ride along were not measured here: reading them as an answer is how
            // one flap retires a pending join for good.
            failures.insert(Self.mappingFailureResult(for: error))
            lastMappingsPassResult = Self.passResult(failures)
            lastMappingsFailureCategory = Self.mappingFailureCategory(for: error)
            resolved.merge(next) { _, new in new }
            // A withdrawal that landed while this pass was suspended still holds, also once the
            // deletion has finished.
            dropWithdrawnKeys(passStartedAt: startedAt)
            noteUnmappedEvidence(locals: locals, resolved: resolvedNow, absent: provenAbsent)
            if !resolved.isEmpty { notifyChromium() }
            announceMappingsResolved(.held)
            return
        }

        let uuidsBeingDeleted = Set(profileIdsBeingDeleted.compactMap {
            profileKeys.mappedGlobalUuid(forProfileId: $0)
        })
        if !hasUnknownLocal, isPairingComplete() {
            let claimed = Set(next.values.map { $0.uuid })
            // Registration waits only for an account Profile that §3.6's twin search
            // or auto-create can still claim onto this Mac, so a same-named local is
            // adopted rather than forked. Two kinds can never be claimed that way and
            // must not hold registration forever: an envelope
            // that does not open under this ARK, and a uuid the persisted mapping
            // already gives to a local Profile that no longer exists (auto-create
            // deliberately never grows that one back).
            var claimable = remoteUuids.subtracting(claimed)
                .subtracting(undecryptableRemoteUuids)
                .subtracting(profileKeys.allMappedGlobalUuids())
            // Auto-create claims only account Profiles with a live Profile entity, so nothing else
            // may hold registration either: a deleted Profile's registry row would hold it
            // forever. Before the first full replay auto-create claims nothing at all, and waiting
            // on it would hold the pause that keeps that replay from running.
            if let profileEntityView {
                if let view = profileEntityView() { claimable.formIntersection(view.liveUuids) }
                else { claimable = [] }
            }
            // D20: no count-based adopt. One unmapped local beside one unclaimed
            // account Profile is not evidence that they are the same Profile; the
            // twin search matches by name and a new local is registered as new (R4).
            if claimable.isEmpty {
                for local in unmappedLocals where !profileIdsBeingCreated.contains(local.profileId) {
                    // Review A11: every registration is a network write sealed with this
                    // controller's ARK; none may start once the account is gone.
                    guard !isRetired else { return }
                    // Checked now, not only when the list was read: the pairing reset may have
                    // deleted this Profile while the pass was suspended.
                    guard !isExcludedFromRegistration(local.profileId) else { continue }
                    do {
                        let rec = try await profileKeys.registerLocalProfile(
                            profileId: local.profileId, displayName: local.displayName,
                            isDefault: local.profileId == LocalStore.defaultProfileId)
                        next[local.profileId] = (rec.uuid, rec.passphrase)
                        resolvedNow.insert(local.profileId)
                        probeResolve("register", profileId: local.profileId, uuid: rec.uuid, passphrase: rec.passphrase)
                    } catch {
                        // `alreadyMapped` cannot normally reach here (only unmapped
                        // locals are in this list); if it does, the next pass sees
                        // the mapping that refused it, so it is transient.
                        let failure = Self.mappingFailureResult(for: error)
                        failures.insert(failure)
                        failureCategory = Self.mappingFailureCategory(for: error)
                        AppLogWarn("[phi-sync] profile registration failed class=\(failure.rawValue) profile=\(local.profileId) (\(PhiSyncLog.describe(error)))")
                    }
                }
            }
        }

        // Review A11: a pass that resumed after retirement must neither cache nor announce.
        guard !isRetired else { return }
        // Monotonic within a signed-in session: merge rather than replace, so a
        // partial pass can never erase a previously-good entry. The cache is
        // fully cleared only by `clearResolved()` (lock / sign-out / switch).
        resolved.merge(next) { _, new in new }
        // A withdrawal that landed while this pass was suspended still holds, also once the
        // deletion has finished.
        dropWithdrawnKeys(passStartedAt: startedAt)
        // Set by the one branch that assigns the predicates, so the announcement's
        // marker follows the assignment itself rather than a re-derived condition.
        var outcome = MappingsOutcome.held
        var result = Self.passResult(failures)
        if hasUnknownLocal || failures.contains(.heldTransient) {
            // Undecidable this pass, or a registration a later pass can still make;
            // hold both predicates and the unmapped set.
        } else {
            let claimedAfter = Set(next.values.map { $0.uuid })
            let stillUnmapped = locals.filter {
                next[$0.profileId] == nil && !isExcludedFromRegistration($0.profileId)
            }
            // The account Profile of a Profile being deleted here is neither unclaimed nor owed.
            var stillUnclaimed = remoteUuids.subtracting(claimedAfter).subtracting(uuidsBeingDeleted)
            // A registry row with no live Profile entity is not an account Profile this Mac lacks.
            if let view = profileEntityView?() { stillUnclaimed.formIntersection(view.liveUuids) }
            needsPairing = !stillUnmapped.isEmpty || !stillUnclaimed.isEmpty
            needsPairingActionable = !stillUnmapped.isEmpty
                || !stillUnclaimed.subtracting(undecryptableRemoteUuids).isEmpty
            provenAbsent.formUnion(stillUnmapped.map(\.profileId))
            if result == .measured, !stillUnmapped.isEmpty, let autoCreateFailure = lastAutoCreateFailure {
                result = autoCreateFailure
                failureCategory = lastAutoCreateFailureCategory
            }
            outcome = .measured
        }
        lastMappingsPassResult = result
        lastMappingsFailureCategory = result == .measured ? nil : failureCategory
        noteUnmappedEvidence(locals: locals, resolved: resolvedNow, absent: provenAbsent)
        AppLogInfo("[phi-sync-probe] resolved=\(resolved.count) needsPairing=\(needsPairing) actionable=\(needsPairingActionable) outcome=\(outcome.rawValue) result=\(result.rawValue)")
        if !resolved.isEmpty { notifyChromium() }
        announceMappingsResolved(outcome)
        // After the announcement: the backfill reads nothing this pass decides
        // and must never delay or hold it.
        backfillProfileDefaultFlagsBestEffort()
    }

    /// Writes the `"default"` flag into this Mac's mapped legacy envelopes so
    /// OTHER devices' pairing can tell its Default from its other Profiles. Only
    /// they read it: this Mac's rounds, Chromium keys and Space landing never
    /// do, so this is strictly best effort. It never sets the pass result or
    /// failure category, never holds an announcement and never withholds keys.
    /// Single-flight: a pass ending while one runs leaves the work to the next
    /// pass. Each failure is logged once per uuid and retried by later passes.
    private func backfillProfileDefaultFlagsBestEffort() {
        guard !isRetired, isCurrentAccount(), manager.currentARK != nil,
              defaultFlagBackfillTask == nil else { return }
        let mappings = profileKeys.allMappings()
        let pending = localProfilesProvider().compactMap { local -> (profileId: String, uuid: String)? in
            guard let uuid = mappings[local.profileId],
                  confirmedDefaultFlagUuids[local.profileId] != uuid else { return nil }
            return (local.profileId, uuid)
        }
        guard !pending.isEmpty else { return }
        defaultFlagBackfillTask = Task { @MainActor [weak self] in
            defer { self?.defaultFlagBackfillTask = nil }
            for local in pending {
                guard let self, !Task.isCancelled, !self.isRetired, self.isCurrentAccount() else { return }
                do {
                    let confirmed = try await self.profileKeys.backfillDefaultFlag(
                        profileId: local.profileId, isDefault: local.profileId == LocalStore.defaultProfileId,
                        isCurrent: { [weak self] in
                            guard let self else { return false }
                            return !self.isRetired && self.isCurrentAccount()
                        })
                    if confirmed { self.confirmedDefaultFlagUuids[local.profileId] = local.uuid }
                } catch {
                    guard !self.isRetired, !(error is CancellationError) else { continue }
                    if self.loggedDefaultFlagFailureUuids.insert(local.uuid).inserted {
                        // R12: 8 characters of the account-global uuid only.
                        AppLogWarn("[phi-sync] profile default-flag backfill failed uuid=\(String(local.uuid.prefix(8))); retried next pass (\(PhiSyncLog.describe(error)))")
                    }
                }
            }
        }
    }

    /// Updates `knownUnmappedProfileIds` from one pass: Profiles that no longer
    /// exist locally leave, Profiles it proved unmapped enter, and Profiles it
    /// resolved leave last (a 404 that the same pass re-registered is resolved).
    /// Nothing else leaves, whatever the pass result. A list that has never been
    /// enumerated prunes nothing (AM-1): its emptiness is not a deletion.
    private func noteUnmappedEvidence(locals: [(profileId: String, displayName: String)],
                                      resolved: Set<String>, absent: Set<String>) {
        if isProfileListEnumerated() {
            knownUnmappedProfileIds.formIntersection(locals.map(\.profileId))
        }
        knownUnmappedProfileIds.formUnion(absent)
        knownUnmappedProfileIds.subtract(resolved)
    }

    /// Every announcement states its outcome; there is no unmarked variant, so an
    /// observer never has to guess what `false, false` meant. A poster that says
    /// nothing (there is none today) is read as `.held` by the gate -- the safe
    /// direction, since only `.measured` retires a pending join.
    private func announceMappingsResolved(_ outcome: MappingsOutcome) {
        NotificationCenter.default.post(
            name: .phiProfileMappingsDidResolve, object: self,
            userInfo: [Self.mappingsOutcomeKey: outcome.rawValue])
    }

    /// The class of one register / adopt / lookup failure (BH-15), from the error
    /// types the key layer actually throws: `KeyAPIError` from the envelope
    /// client, `ProfileKeyManagerError`, and the crypto and decoding errors of
    /// opening an envelope. Transient means a later pass can succeed with no
    /// user action: no response, a token being renewed or a session changing
    /// (401/403), the server asking for a later try (408/429/5xx), the ARK not
    /// unlocked yet, a mapping that moved under the pass. Definitive means the
    /// server or the envelope refused (an unexpected 4xx, a body or envelope that
    /// does not decode or open). Anything else is transient: before this
    /// classification every failure was retried on the next trigger, and that
    /// stays the default.
    nonisolated static func mappingFailureResult(for error: Error) -> SyncProfileMappingPassResult {
        switch error {
        case let error as KeyAPIError:
            switch error {
            case .transport: return .heldTransient
            case .http(let status, _):
                let transient = status == 0 || status == 401 || status == 403 || status == 408
                    || status == 429 || status >= 500
                return transient ? .heldTransient : .definitiveFailure
            case .decode, .lastActiveDevice, .notLastDevice, .deviceNotFound: return .definitiveFailure
            }
        case let error as ProfileKeyManagerError:
            switch error {
            case .notUnlocked, .alreadyMapped, .metadataConflict: return .heldTransient
            case .badEnvelope, .defaultMismatch: return .definitiveFailure
            }
        case is PhiKeyCryptoError, is CryptoKitError, is DecodingError:
            return .definitiveFailure
        default:
            return .heldTransient
        }
    }

    /// The status-only category of one failure. Offline is a transport error that
    /// means no connectivity; a missing token (the client's
    /// `userAuthenticationRequired` transport error) reads as sign-in expired,
    /// like 401 and 403; 5xx, 429 and 408 are server errors; everything else,
    /// a definitive refusal included, is other.
    nonisolated static func mappingFailureCategory(for error: Error) -> SyncProfileMappingFailureCategory {
        guard let error = error as? KeyAPIError else { return .other }
        switch error {
        case .transport(let underlying):
            guard let urlError = underlying as? URLError else { return .other }
            switch urlError.code {
            case .userAuthenticationRequired: return .signInExpired
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost,
                 .dnsLookupFailed, .timedOut, .internationalRoamingOff, .dataNotAllowed:
                return .offline
            default: return .other
            }
        case .http(let status, _):
            if status == 401 || status == 403 { return .signInExpired }
            if status >= 500 || status == 429 || status == 408 { return .serverError }
            return .other
        case .decode, .lastActiveDevice, .notLastDevice, .deviceNotFound: return .other
        }
    }

    /// A definitive failure outranks a transient one: retrying cannot clear it.
    private static func passResult(_ failures: Set<SyncProfileMappingPassResult>) -> SyncProfileMappingPassResult {
        if failures.contains(.definitiveFailure) { return .definitiveFailure }
        if failures.contains(.heldTransient) { return .heldTransient }
        return .measured
    }

    /// The one entry the pause's retry drives. §3.6's
    /// auto-create (twin search, then create) runs FIRST and the mapping pass
    /// second: an account Profile that auto-create claims leaves the unclaimed set
    /// before the pass decides whether to register, so a same-named local is
    /// adopted and a dead mapping heals onto its own uuid instead of forking a new
    /// one. Nothing here goes through the engine, so it works while the engine is
    /// stopped. Both halves keep their own gates -- auto-create runs only with
    /// enrollment complete, and neither step writes while locked -- and both are
    /// single-flight: a caller arriving while either runs joins it.
    func runMappingRepairPass() async {
        guard !isRetired else { return }
        _ = await ensureLocalProfilesForAccount()
        guard !isRetired else { return }
        await resolveMappings()
    }

    // MARK: - §3.6 Runtime profile auto-create

    static let maxAutoCreatesPerRound = 3

    /// The candidate scan of a round whose local Default is free: at most this
    /// many envelope reads in flight, and the whole scan bounded by
    /// `candidateScanDeadline`, so one slow request cannot hold the sync round
    /// (the engine awaits this refresh before it pulls pages).
    static let candidateScanWidth = 3
    /// An instance property, not a constant, only so the hostless fixture can
    /// shorten it; production never changes it.
    var candidateScanDeadline: Duration = .seconds(10)

    /// Profiles created by the most recent refresh, for §11's `profiles_created`
    /// counter. Read through `PhiSpaceLocalAccess.profilesCreatedInLastRefresh()`.
    private(set) var lastRefreshCreatedCount = 0

    /// Local profiles this controller created FOR an account uuid but has not
    /// managed to map yet, keyed by that uuid. `adoptRemoteProfile` writes the
    /// mapping only after the envelope is fetched and opened
    /// (ProfileKeyManager.swift:115-118), so a 404/5xx/offline blip inside it
    /// leaves the freshly created profile sitting on disk with nothing pointing
    /// at it.
    ///
    /// The same-named twin search below cannot recover that profile: the name it
    /// actually carries is `uniqueDisplayName`'s output, i.e. "Work (2)" whenever
    /// a MAPPED local already holds "Work" -- the ordinary two-device case, where
    /// both Macs made a "Work" profile and each registered its own uuid. The twin
    /// search matches `remote.name` ("Work"), so without this record every failed
    /// round would create "Work (3)", "Work (4)", … and leave each predecessor
    /// behind; `resolveMappings()`'s register branch then pushes those empty
    /// profiles to the account, and §3.6 on every other device auto-creates them
    /// too. One blip would propagate an empty duplicate account-wide.
    ///
    /// In memory only, and deliberately so: it is a retry hint, never a source of
    /// truth. A relaunch drops it and the un-suffixed half of the case is still
    /// covered by the twin search; every read revalidates the entry
    /// (`reusablePendingProfile(forUuid:)`) rather than trusting it.
    private var pendingCreatedProfiles: [String: String] = [:]

    /// The pending profile for `uuid`, but only when it is still a real,
    /// user-assignable, still-unmapped local. A profile the user deleted in the
    /// meantime, or one `resolveMappings()` registered under its own uuid while
    /// the adopt kept failing, is not a candidate -- and the stale entry is
    /// dropped here rather than left to accumulate for the life of the process.
    private func reusablePendingProfile(forUuid uuid: String) -> String? {
        guard let profileId = pendingCreatedProfiles[uuid] else { return nil }
        let stillExists = profileCreator.userAssignableProfileIds.contains { $0.profileId == profileId }
        guard stillExists, profileKeys.mappedGlobalUuid(forProfileId: profileId) == nil else {
            pendingCreatedProfiles[uuid] = nil
            return nil
        }
        return profileId
    }

    /// Create a local Chromium profile for an account profile and claim it. The
    /// ONE implementation, shared by the pairing modal's `.createLocal` and by
    /// §3.6's auto-create -- two copies would diverge immediately (the automatic
    /// side has to pre-check the name, refuse an unopenable envelope and run a
    /// wrap-up resolve).
    ///
    /// Ordering is load-bearing: create -> fetch and OPEN the envelope under the
    /// ARK -> only then write the mapping (`adoptRemoteProfile`,
    /// ProfileKeyManager.swift:115-118). An envelope that will not open therefore
    /// leaves NO mapping behind, which is what makes both retries work next
    /// round: `pendingCreatedProfiles` for the profile this call created, and the
    /// "adopt the same-named unmapped profile" search for the un-suffixed case.
    ///
    /// A retired controller creates, adopts and maps nothing and throws
    /// `CancellationError`. A bridge create that completes after retirement may
    /// have made the Profile already; it is left local and unmapped, never
    /// deleted, and never enters `profileIdsBeingCreated`.
    func createLocalProfileAndAdopt(uuid: String, displayName: String) async throws -> String {
        guard !isRetired else { throw CancellationError() }
        let profileId: String
        if let pending = reusablePendingProfile(forUuid: uuid) {
            // A previous attempt already made a profile for exactly this uuid and
            // only the adopt failed. Re-adopt onto it; creating a second one is
            // how one network blip becomes a permanent empty duplicate.
            profileId = pending
        } else {
            let name = Self.uniqueDisplayName(basedOn: displayName) { profileCreator.displayNameExists($0) }
            let result = await profileCreator.createProfile(displayName: name)
            guard !isRetired else {
                // R12: metadata only, no profileId or uuid.
                AppLogInfo("[phi-sync] controller retired while a profile was being created; created=\(result != nil), left local and unmapped")
                throw CancellationError()
            }
            guard let created = result else {
                throw ProfileKeyManagerError.badEnvelope
            }
            // Recorded BEFORE the adopt, because the adopt is the step that can
            // throw and the profile already exists on disk by now.
            pendingCreatedProfiles[uuid] = created
            profileId = created
        }
        // The pause ignores this Profile until the adopt below has finished or
        // failed. The bridge publishes a new Profile before `createProfile`
        // returns, so the Profile-list sink sees it one step before it is here.
        profileIdsBeingCreated.insert(profileId)
        var adopted = false
        defer {
            profileIdsBeingCreated.remove(profileId)
            // No pass follows a failed adopt; announce so the pause counts this
            // Profile now instead of at the next trigger. A retired controller
            // announces nothing.
            if !adopted, !isRetired { announceMappingsResolved(.held) }
        }
        // The create is this round's only suspension, and `$profiles` runs a
        // `resolveMappings()` pass inside it; whatever claimed this very uuid
        // onto another local meanwhile (a pairing decision) wins. Adopting
        // anyway would leave two locals on one uuid.
        if profileKeys.localProfileId(forGlobalUuid: uuid) != nil {
            // The uuid now belongs to another local, so it leaves §3.6's
            // `missing` set and this profile is NOT revisited by the next round.
            // It stays a plain unmapped local, which `resolveMappings()` registers
            // under a uuid of its own once every account profile is claimed. The
            // pending entry is kept, not dropped: if §6.2 A0 later removes the
            // mapping that won the race, this profile is the right one to reuse.
            AppLogInfo("[phi-sync] uuid was claimed while the profile was being created; the new profile stays local and unmapped")
            return profileId
        }
        // A profile this creates is never the Default. Callers never create one
        // for the authoritative account default; a demoted extra default is an
        // ordinary profile.
        _ = try await profileKeys.adoptRemoteProfile(uuid: uuid, forLocalProfile: profileId, isDefault: false)
        // The adopt writes its mapping right after its lookup returns; a
        // retirement inside that lookup cannot be fenced from here. Record nothing
        // more for the controller that is gone.
        guard !isRetired else { throw CancellationError() }
        adopted = true
        // Resolved: a pass that holds before it looks again must not keep pausing for it.
        knownUnmappedProfileIds.remove(profileId)
        pendingCreatedProfiles[uuid] = nil
        return profileId
    }

    /// The suffix is decided by a PRE-CHECK, never by probing the return value:
    /// `createProfile` returns nil for three different reasons (empty or
    /// duplicate name, no bridge, bridge-side failure), so "nil means duplicate,
    /// try the next suffix" turns a missing bridge into unbounded probing.
    /// Shared with the Profile entity's inbound rename (`PhiProfileLocalAccess.applyRemoteName`),
    /// which passes a `nameExists` that excludes the Profile being renamed.
    static func uniqueDisplayName(basedOn raw: String, nameExists: (String) -> Bool) -> String {
        let base = raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? NSLocalizedString("sync.pairing.unnamedProfileName", value: "Profile", comment: "Sync setup - name given to a local profile created for an account profile that has no name")
            : raw
        guard nameExists(base) else { return base }
        for suffix in 2...50 {
            let candidate = "\(base) (\(suffix))"
            if !nameExists(candidate) { return candidate }
        }
        return "\(base) (\(UUID().uuidString.prefix(4)))"
    }

    /// Once per pull round: compare the account's profile list against this
    /// device's PERSISTED mapping and create whatever is missing. No prompt, no
    /// UI. Never runs while the Space gate is shut -- during a join, "the account
    /// has a profile this Mac does not" is exactly the ambiguity the modal exists
    /// to resolve, and auto-claiming would take the choice away from the user.
    ///
    /// Single-flight since the repair pass calls it from
    /// outside the engine as well: two rounds interleaving at their awaits would
    /// both see the same uuid missing and each create a Profile for it. A caller
    /// arriving mid-round gets that round's outcome.
    func ensureLocalProfilesForAccount() async -> ProfileRefreshOutcome {
        if let running = autoCreateTask { return await running.value }
        let task = Task { @MainActor [weak self] () -> ProfileRefreshOutcome in
            guard let self else { return .failed }
            let outcome = await self.ensureLocalProfilesForAccountOnce()
            // No suspension between the round's end and this write, as in `resolveMappings()`.
            self.autoCreateTask = nil
            return outcome
        }
        autoCreateTask = task
        return await task.value
    }

    private var autoCreateTask: Task<ProfileRefreshOutcome, Never>?

    private func ensureLocalProfilesForAccountOnce() async -> ProfileRefreshOutcome {
        guard !isRetired else { return retiredRefresh() }
        // Same gate as the Space section (§3.5), not modal visibility: flag-setting and presentation are
        // separate events, and relaunch during pairing adds another gap. A gate-closed round is
        // profile_refresh=skipped, explicitly not failure (§11). Reporting failed would miscount and make the
        // engine retry an intentional no-op.
        guard isPairingComplete() else {
            return await finishRefresh(.skipped, created: 0, skipped: 0)
        }
        // R4: auto-create follows the drained account's Profile entities. Before the first full
        // replay nothing is known about which Profiles still exist, so nothing is created.
        let entityView = profileEntityView?()
        if profileEntityView != nil, entityView == nil {
            return await finishRefresh(.skipped, created: 0, skipped: 0)
        }
        lastAutoCreateFailure = nil
        lastAutoCreateFailureCategory = nil
        let accountUuids: Set<String>
        do {
            accountUuids = try await profileKeys.accountProfileUuids()
            // The listing may have answered for the next account (review A11).
            guard !isRetired else { return retiredRefresh() }
            lastAccountProfileUuids = accountUuids
        } catch {
            guard !isRetired else { return retiredRefresh() }
            noteAutoCreateFailure(error)
            AppLogWarn("[phi-sync] account profile refresh failed (\(PhiSyncLog.describe(error)))")
            return await finishRefresh(.failed, created: 0, skipped: 0)
        }
        // The LEFT side is the persisted mapping, not the local profile list: a
        // profile the user deleted keeps its mapping entry, so it is not
        // "missing" and never grows back (§3.6). The one exception is §6.2 A0's
        // dead-mapping cleanup, which removes the entry first.
        let mapped = Set(profileKeys.allMappedGlobalUuids())
        // Only uuids with a live Profile entity: a deleted Profile's registry row stays forever and
        // must never grow the Profile back on a device that did not have it.
        var missingSet = accountUuids.subtracting(mapped)
        if let entityView { missingSet.formIntersection(entityView.liveUuids) }
        let missing = missingSet.sorted()   // uuid order: device-independent
        guard !missing.isEmpty else { return await finishRefreshAndBackfill(.unchanged, created: 0, skipped: 0) }
        // The Profile entity carries the account's current name; the registry envelope keeps
        // the name it was registered under and is only the fallback.
        let displayName: (String, String) -> String = { uuid, registryName in
            let entityName = entityView?.liveNames[uuid] ?? ""
            return entityName.isEmpty ? registryName : entityName
        }

        var created = 0
        var skipped = 0
        // BH-16: the cap counts attempts, not successes, so a round whose creates
        // keep failing still stops after `maxAutoCreatesPerRound` of them.
        var attempts = 0
        // A local counts as taken only while its persisted uuid is still in this
        // round's account listing (see `claimMissingProfile`).
        let liveMappedIds = Set(profileKeys.allMappings().filter { accountUuids.contains($0.value) }.keys)
        let localDefaultFree = profileCreator.userAssignableProfileIds.contains {
            $0.profileId == LocalStore.defaultProfileId && !liveMappedIds.contains($0.profileId)
        }

        if !localDefaultFree {
            // The local Default cannot be claimed this round, so the order of
            // claims does not matter (any flagged default is demoted): stream,
            // with the cap checked BEFORE each read, so a round reads at most
            // `maxAutoCreatesPerRound` envelopes it then acts on.
            for uuid in missing {
                guard attempts < Self.maxAutoCreatesPerRound else { skipped += 1; continue }
                let remote: RemoteProfile
                do {
                    remote = try await profileKeys.remoteProfile(uuid: uuid)
                    guard !isRetired else { return retiredRefresh() }
                } catch {
                    guard !isRetired else { return retiredRefresh() }
                    noteAutoCreateFailure(error)
                    skipped += 1; continue
                }
                guard let name = remote.name else {
                    // No per-profile key means a profile that could not sync anything
                    // and a mystery entry in the user's list. Skip, record, retry.
                    noteUndecryptableRemote(uuid)
                    AppLogInfo("[phi-sync] account profile envelope will not open uuid=\(String(uuid.prefix(8)))")
                    skipped += 1
                    continue
                }
                noteDecryptableRemote(uuid)
                attempts += 1
                switch await claimMissingProfile(remote, name: displayName(uuid, name), accountUuids: accountUuids,
                                                 defaultClosedToUnflagged: false) {
                case .claimed: created += 1
                case .failed: skipped += 1
                case .retired: return retiredRefresh()
                }
            }
        } else {
            // The local Default is free, and which remote takes it depends on the
            // flags: a legacy profile that merely shares the Default's name must
            // not take it ahead of the account default that sorts after it. Read
            // the candidates first -- bounded in width and time -- then claim the
            // flagged account defaults first, everything else after, uuid order
            // within each group.
            let scan = await scanMissingProfiles(missing)
            guard !scan.retired, !isRetired else { return retiredRefresh() }
            skipped += missing.count - scan.candidates.count
            let candidates = scan.candidates.filter { $0.remote.isDefault == true }
                + scan.candidates.filter { $0.remote.isDefault != true }
            // An unread remote may be the account default (a 503, a timeout), so
            // an incomplete scan closes the Default to unflagged remotes exactly
            // as a flagged one among the candidates does -- even when that one's
            // own adopt fails. The Default stays free and the next round retries.
            let defaultClosedToUnflagged = scan.incomplete || candidates.contains { $0.remote.isDefault == true }
            for (remote, name) in candidates {
                guard attempts < Self.maxAutoCreatesPerRound else { skipped += 1; continue }
                attempts += 1
                switch await claimMissingProfile(remote, name: displayName(remote.uuid, name), accountUuids: accountUuids,
                                                 defaultClosedToUnflagged: defaultClosedToUnflagged) {
                case .claimed: created += 1
                case .failed: skipped += 1
                case .retired: return retiredRefresh()
                }
            }
        }
        return await finishRefreshAndBackfill(created > 0 ? .changed : .unchanged, created: created, skipped: skipped)
    }

    private enum MissingProfileClaim { case claimed, failed, retired }

    /// One decrypted account profile this Mac has no mapping for: twin it onto a
    /// same-named unmapped local, or create a local for it. The caller has
    /// already counted the attempt. `defaultClosedToUnflagged` keeps a free local
    /// Default away from every remote that is not a flagged account default.
    private func claimMissingProfile(_ remote: RemoteProfile, name: String, accountUuids: Set<String>,
                                     defaultClosedToUnflagged: Bool) async -> MissingProfileClaim {
        let uuid = remote.uuid
        // A local counts as taken only while its persisted uuid is still in
        // this round's account listing: a mapping whose envelope is gone
        // (404) must not stop the local -- the Default above all -- from
        // claiming a live account profile, or the next pass registers yet
        // another uuid for it.
        let mappedIds = Set(profileKeys.allMappings().filter { accountUuids.contains($0.value) }.keys)
        // The default-profile rule: the local Default is a twin only for an
        // account default (whatever its name) or a legacy profile. While the
        // local Default is free, an account default goes to it and nowhere
        // else. Once the Default is live-mapped, its uuid is the one
        // authoritative account default and any other is demoted to an
        // ordinary profile -- twinned by name or created like any other --
        // so nothing a concurrent pairing registered is left unclaimed.
        let defaultTwin = profileCreator.userAssignableProfileIds.first(where: {
            $0.profileId == LocalStore.defaultProfileId && !mappedIds.contains($0.profileId)
        })
        let effective: RemoteProfile
        if remote.isDefault == true, defaultTwin == nil {
            effective = RemoteProfile(uuid: uuid, name: name, isDefault: false)
            if loggedDefaultConflictUuids.insert(uuid).inserted {
                AppLogWarn("[phi-sync] default-identity conflict: extra account default treated as an ordinary profile uuid=\(String(uuid.prefix(8)))")
            }
        } else {
            effective = remote
        }

        // Claim an existing same-named UNMAPPED local first. This covers the
        // plain coincidence of two devices having made the same name, and the
        // un-suffixed half of "last round created it but the adopt failed".
        // The enumeration source is `userAssignableProfileIds`, never the
        // whole `ProfileManager.profiles`: the agent fallback profile is in
        // the latter and must never be handed to the account.
        //
        // A profile THIS controller created for THIS uuid outranks any name
        // match, so the twin search stands down when one exists: going by name
        // first would adopt a different local and orphan the created one for
        // good. `createLocalProfileAndAdopt` picks it up below.
        if reusablePendingProfile(forUuid: uuid) == nil,
           let twin = effective.isDefault == true ? defaultTwin : profileCreator.userAssignableProfileIds.first(where: {
            !mappedIds.contains($0.profileId) && !isExcludedFromRegistration($0.profileId)
            && !(defaultClosedToUnflagged && $0.profileId == LocalStore.defaultProfileId)
            && effective.mayPair(withLocalDefault: $0.profileId == LocalStore.defaultProfileId,
                                 authoritativeDefaultUuid: nil)
            && $0.displayName.caseInsensitiveCompare(name) == .orderedSame
        }) {
            do {
                _ = try await profileKeys.adoptRemoteProfile(
                    uuid: uuid, forLocalProfile: twin.profileId,
                    isDefault: twin.profileId == LocalStore.defaultProfileId)
                guard !isRetired else { return .retired }
                knownUnmappedProfileIds.remove(twin.profileId)
                return .claimed
            } catch {
                guard !isRetired else { return .retired }
                noteAutoCreateFailure(error)
                AppLogInfo("[phi-sync] twin adopt failed uuid=\(String(uuid.prefix(8))) (\(PhiSyncLog.describe(error)))")
                return .failed
            }
        }
        do {
            _ = try await createLocalProfileAndAdopt(uuid: uuid, displayName: name)
            guard !isRetired else { return .retired }
            return .claimed
        } catch {
            guard !isRetired else { return .retired }
            noteAutoCreateFailure(error)
            AppLogInfo("[phi-sync] auto-create failed uuid=\(String(uuid.prefix(8))) (\(PhiSyncLog.describe(error)))")
            return .failed
        }
    }

    private enum CandidateRead: Sendable {
        case read(RemoteProfile)
        case failed(any Error)
        case deadline
    }

    /// Reads the envelopes of `missing` with at most `candidateScanWidth` in
    /// flight, until `candidateScanDeadline`. `incomplete` is set by any read
    /// error and by the deadline (an envelope that does not open is a known
    /// non-candidate, not incomplete). Undecryptable and failure bookkeeping is
    /// done here for what was read; reads still in flight at the deadline are
    /// cancelled and counted by the caller as skipped. Candidates come back in
    /// uuid order.
    private func scanMissingProfiles(
        _ missing: [String]
    ) async -> (candidates: [(remote: RemoteProfile, name: String)], incomplete: Bool, retired: Bool) {
        var read: [String: RemoteProfile] = [:]
        var incomplete = false
        var retired = false
        let deadline = candidateScanDeadline
        await withTaskGroup(of: CandidateRead.self) { group in
            group.addTask {
                try? await Task.sleep(for: deadline)
                return .deadline
            }
            var pending = missing[...]
            var inFlight = 0
            func start(_ uuid: String) {
                group.addTask { @MainActor [weak self] in
                    guard let self else { return .failed(CancellationError()) }
                    do { return .read(try await self.profileKeys.remoteProfile(uuid: uuid)) }
                    catch { return .failed(error) }
                }
                inFlight += 1
            }
            while inFlight < Self.candidateScanWidth, let uuid = pending.popFirst() { start(uuid) }
            scan: while inFlight > 0, let result = await group.next() {
                switch result {
                case .deadline:
                    incomplete = true
                    AppLogInfo("[phi-sync] account profile scan hit its \(deadline) deadline; \(inFlight + pending.count) unread")
                    break scan
                case .read(let remote):
                    inFlight -= 1
                    read[remote.uuid] = remote
                case .failed(let error):
                    inFlight -= 1
                    incomplete = true
                    if !isRetired { noteAutoCreateFailure(error) }
                }
                if isRetired { retired = true; break scan }
                if let uuid = pending.popFirst() { start(uuid) }
            }
            // The deadline sleeper, and whatever is still in flight.
            group.cancelAll()
        }
        guard !retired, !isRetired else { return ([], incomplete, true) }
        var candidates: [(remote: RemoteProfile, name: String)] = []
        for uuid in missing {
            guard let remote = read[uuid] else { continue }
            guard let name = remote.name else {
                noteUndecryptableRemote(uuid)
                AppLogInfo("[phi-sync] account profile envelope will not open uuid=\(String(uuid.prefix(8)))")
                continue
            }
            noteDecryptableRemote(uuid)
            candidates.append((remote, name))
        }
        return (candidates, incomplete, false)
    }

    /// The periodic sync round reaches the key layer through this refresh, not
    /// through `resolveMappings()`, so a round that read the account listing
    /// also retries the best-effort default-flag backfill. Confirmed uuids are
    /// cached, so once the flags are written this costs nothing.
    private func finishRefreshAndBackfill(_ outcome: ProfileRefreshOutcome,
                                          created: Int, skipped: Int) async -> ProfileRefreshOutcome {
        let result = await finishRefresh(outcome, created: created, skipped: skipped)
        backfillProfileDefaultFlagsBestEffort()
        return result
    }

    /// A round stopped by `retire()`: `.failed`, as `PhiSpaceLocalAccess` answers
    /// for a dropped controller, and no `.phiProfileAutoCreateDidRun`, as a
    /// retired pass announces nothing either.
    private func retiredRefresh() -> ProfileRefreshOutcome {
        AppLogInfo("[phi-sync] auto-create round stopped: the controller was retired")
        return .failed
    }

    /// Keeps the worse of this round's failures; a definitive one outranks a transient one.
    private func noteAutoCreateFailure(_ error: Error) {
        let failure = Self.mappingFailureResult(for: error)
        if lastAutoCreateFailure != .definitiveFailure {
            lastAutoCreateFailure = failure
            lastAutoCreateFailureCategory = Self.mappingFailureCategory(for: error)
        }
    }

    private func finishRefresh(_ outcome: ProfileRefreshOutcome,
                               created: Int, skipped: Int) async -> ProfileRefreshOutcome {
        lastRefreshCreatedCount = created
        if outcome == .changed {
            // Not optional bookkeeping: the new profile's passphrase reaches
            // `resolved` (and Chromium) ONLY here. `$profiles` cannot do it -- its
            // pass runs before `adoptRemoteProfile` writes the mapping -- and it
            // never self-heals, because next round the mapping exists and the uuid
            // is no longer missing.
            await resolveMappings()
            guard !isRetired else { return retiredRefresh() }
        }
        let label: String
        switch outcome {
        case .changed: label = "changed"
        case .failed: label = "failed"
        // The gate-shut round is not a stall the hysteresis should count, and it
        // is not a failure either -- `ProfilePairingGate` treats it exactly like
        // `.failed`: reset nothing, advance nothing.
        case .skipped: label = "skipped"
        case .unchanged: label = "unchanged"
        }
        NotificationCenter.default.post(
            name: .phiProfileAutoCreateDidRun, object: self,
            userInfo: ["outcome": label, "created": created, "skippedUuids": skipped])
        return outcome
    }

    /// Temporary M2-5 diagnostic (issue 2, Needs-passphrase): identify resolved keys by source to compare
    /// delivered passphrases across sessions. A changed hash for the same UUID signals envelope/keybag
    /// desynchronization. Log only a short SHA-256 prefix, never the passphrase; remove after diagnosing issue
    /// 2.
    ///
    /// R12 truncates account UUIDs to eight characters, like other milestone UUID/tag hashes. AppLogInfo
    /// reaches the support-uploaded CocoaLumberjack file, which must never contain full profile_uuid values.
    private func probeResolve(_ source: String, profileId: String, uuid: String, passphrase: String) {
        let ppHash = SHA256.hash(data: Data(passphrase.utf8)).prefix(6)
            .map { String(format: "%02x", $0) }.joined()
        AppLogInfo("[phi-sync-probe] resolve source=\(source) profile=\(profileId) uuid=\(String(uuid.prefix(8))) ppHash=\(ppHash)")
    }
}

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
    var requiresReconfiguration: Bool { markerStore?.load().requiresReconfiguration == true || runtimeRequiresReconfiguration() }

    private let isPairingComplete: @MainActor () -> Bool
    /// `ProfileManager.isProfileListEnumerated`: until the list has been read once, an
    /// empty `localProfilesProvider()` answer says nothing about which Profiles exist, so
    /// the unmapped evidence is not pruned against it (docs/sync.md, "Enrollment and setup").
    private let isProfileListEnumerated: @MainActor () -> Bool
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
         runtimeRemovalPending: @escaping () -> Bool = { false }) {
        self.isPairingComplete = isPairingComplete
        self.isProfileListEnumerated = isProfileListEnumerated
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
    }

    /// While true, `profileSyncInfo` answers nil for every Profile; setting it
    /// back hands out the same values again, because resolution and the cache
    /// carry on underneath. Withdrawing a key stops a Chromium engine without
    /// clearing its metadata (docs/sync.md, "Chromium account and key
    /// lifecycle"). Plain state: its owner decides when to set it and pings
    /// Chromium itself.
    var chromiumKeysWithdrawn = false

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

    /// Called only after explicit reconfiguration confirmation. Ordinary setup/retry
    /// never calls this method. A partial removal also resumes through this path.
    func reconfigureSync() async throws {
        guard !isRetired, !cleaningLocalState, isCurrentAccount(), requiresReconfiguration else {
            throw CancellationError()
        }
        cleaningLocalState = true
        defer { cleaningLocalState = false }
        try await clearLocalSyncState(removingDevice: markerStore?.load().removalPending == true || runtimeRemovalPending())
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
            var journal = markerStore.load()
            journal.requiresReconfiguration = true
            journal.removalPending = removingDevice
            guard markerStore.save(journal) else { throw NativeSyncResetError.cleanupFailed }
        }
        try invalidateEnrollment()
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
        for key in PhiSyncEngine.stateKeys + PhiSyncEngine.legacyMarkerStateKeys + ["phi.sync.requiresReconfiguration"] {
            engineDefaults.removeObject(forKey: key)
        }
        for key in engineDefaults.dictionaryRepresentation().keys
            where key.hasSuffix(SyncableSettings.timestampSuffix) || key.hasSuffix(SyncableSettings.valueSuffix) {
            engineDefaults.removeObject(forKey: key)
        }
        // This mirrored value is a sync UUID, not the user's local default Space.
        engineDefaults.removeObject(forKey: PhiDefaultSpaceMirror.key)
        if let spaceStateStore, !spaceStateStore.save(PhiSpaceSyncTable()) {
            throw NativeSyncResetError.cleanupFailed
        }
        PhiSpaceSyncState.shared.refreshCaches(from: PhiSpaceSyncTable())
        markerStore?.deleteFile()
        guard markerStore?.load().requiresReconfiguration != true else {
            throw NativeSyncResetError.cleanupFailed
        }
        completed = true
        AppLogInfo("[phi-sync] confirmed local sync cleanup completed")
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
    /// `.phiAccountKeyDidUnlock`, so a later trigger retries.
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
                clearResolved()  // transient (offline etc.) — the first unlock's notification retries
                return
            }
            AppLogWarn("[phi-sync] silent unlock failed with the account key held; keeping resolved keys (\(PhiSyncLog.describe(error)))")
            await resolveMappings()
            return
        }
        guard !isRetired else { return }
        switch result {
        case .unlocked:
            break
        case .needsJoin:
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
        autoCreateTask?.cancel()
        clearResolved()
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

    /// Single-flight state for `silentUnlockAndResolve()`. It is entered from the
    /// startup/login unlock and from the Profile-list follow-up, and the two can
    /// overlap: one pass resolved the keys, then the other's device-envelope
    /// lookup failed (an offline blip, a 45 s request timeout) and its
    /// `clearResolved()` wiped what the first had just resolved, so Chromium
    /// pulled nil and sync silently stopped (BH-52). So: one unlock pass at a
    /// time, later callers coalesce into exactly one follow-up pass.
    private var silentUnlockTask: Task<Void, Never>?
    private var silentUnlockPending = false

    private func resolveMappingsOnce() async {
        guard !isRetired else { return }
        var next: [String: (uuid: String, passphrase: String)] = [:]
        let locals = localProfilesProvider()
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
            noteUnmappedEvidence(locals: locals, resolved: resolvedNow, absent: provenAbsent)
            if !resolved.isEmpty { notifyChromium() }
            announceMappingsResolved(.held)
            return
        }

        if !hasUnknownLocal, isPairingComplete() {
            let claimed = Set(next.values.map { $0.uuid })
            // Registration waits only for an account Profile that §3.6's twin search
            // or auto-create can still claim onto this Mac, so a same-named local is
            // adopted rather than forked. Two kinds can never be claimed that way and
            // must not hold registration forever: an envelope
            // that does not open under this ARK, and a uuid the persisted mapping
            // already gives to a local Profile that no longer exists (auto-create
            // deliberately never grows that one back).
            let claimable = remoteUuids.subtracting(claimed)
                .subtracting(undecryptableRemoteUuids)
                .subtracting(profileKeys.allMappedGlobalUuids())
            // D20: no count-based adopt. One unmapped local beside one unclaimed
            // account Profile is not evidence that they are the same Profile; the
            // twin search matches by name and a new local is registered as new (R4).
            if claimable.isEmpty {
                for local in unmappedLocals where !profileIdsBeingCreated.contains(local.profileId) {
                    // Review A11: every registration is a network write sealed with this
                    // controller's ARK; none may start once the account is gone.
                    guard !isRetired else { return }
                    do {
                        let rec = try await profileKeys.registerLocalProfile(
                            profileId: local.profileId, displayName: local.displayName)
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
        // Set by the one branch that assigns the predicates, so the announcement's
        // marker follows the assignment itself rather than a re-derived condition.
        var outcome = MappingsOutcome.held
        var result = Self.passResult(failures)
        if hasUnknownLocal || failures.contains(.heldTransient) {
            // Undecidable this pass, or a registration a later pass can still make;
            // hold both predicates and the unmapped set.
        } else {
            let claimedAfter = Set(next.values.map { $0.uuid })
            let stillUnmapped = locals.filter { next[$0.profileId] == nil }
            let stillUnclaimed = remoteUuids.subtracting(claimedAfter)
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
            case .decode, .lastActiveDevice: return .definitiveFailure
            }
        case let error as ProfileKeyManagerError:
            switch error {
            case .notUnlocked, .alreadyMapped: return .heldTransient
            case .badEnvelope: return .definitiveFailure
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
        case .decode, .lastActiveDevice: return .other
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
            let name = uniqueDisplayName(basedOn: displayName)
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
        _ = try await profileKeys.adoptRemoteProfile(uuid: uuid, forLocalProfile: profileId)
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
    private func uniqueDisplayName(basedOn raw: String) -> String {
        let base = raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? NSLocalizedString("sync.pairing.unnamedProfileName", value: "Profile", comment: "Sync setup - name given to a local profile created for an account profile that has no name")
            : raw
        guard profileCreator.displayNameExists(base) else { return base }
        for suffix in 2...50 {
            let candidate = "\(base) (\(suffix))"
            if !profileCreator.displayNameExists(candidate) { return candidate }
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
        lastAutoCreateFailure = nil
        lastAutoCreateFailureCategory = nil
        let accountUuids: Set<String>
        do {
            accountUuids = try await profileKeys.accountProfileUuids()
            // The listing may have answered for the next account (review A11).
            guard !isRetired else { return retiredRefresh() }
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
        let missing = accountUuids.subtracting(mapped).sorted()   // uuid order: device-independent
        guard !missing.isEmpty else { return await finishRefresh(.unchanged, created: 0, skipped: 0) }

        var created = 0
        var skipped = 0
        // BH-16: the cap counts attempts, not successes, so a round whose creates
        // keep failing still stops after `maxAutoCreatesPerRound` of them.
        var attempts = 0
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
            let mappedIds = Set(profileKeys.allMappings().keys)
            if reusablePendingProfile(forUuid: uuid) == nil,
               let twin = profileCreator.userAssignableProfileIds.first(where: {
                !mappedIds.contains($0.profileId)
                && $0.displayName.caseInsensitiveCompare(name) == .orderedSame
            }) {
                attempts += 1
                do {
                    _ = try await profileKeys.adoptRemoteProfile(uuid: uuid, forLocalProfile: twin.profileId)
                    guard !isRetired else { return retiredRefresh() }
                    knownUnmappedProfileIds.remove(twin.profileId)
                    created += 1
                } catch {
                    guard !isRetired else { return retiredRefresh() }
                    noteAutoCreateFailure(error)
                    AppLogInfo("[phi-sync] twin adopt failed uuid=\(String(uuid.prefix(8))) (\(PhiSyncLog.describe(error)))")
                    skipped += 1
                }
                continue
            }
            attempts += 1
            do {
                _ = try await createLocalProfileAndAdopt(uuid: uuid, displayName: name)
                guard !isRetired else { return retiredRefresh() }
                created += 1
            } catch {
                guard !isRetired else { return retiredRefresh() }
                noteAutoCreateFailure(error)
                AppLogInfo("[phi-sync] auto-create failed uuid=\(String(uuid.prefix(8))) (\(PhiSyncLog.describe(error)))")
                skipped += 1
            }
        }
        return await finishRefresh(created > 0 ? .changed : .unchanged, created: created, skipped: skipped)
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

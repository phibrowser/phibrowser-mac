// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import CryptoKit
import Foundation

extension Notification.Name {
    /// Posted at the end of EVERY `SyncKeyController.resolveMappings()` pass,
    /// the ones that bail out early included, and by `clearResolved()`. The
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
    /// return, `.failed` and `.skipped` included. userInfo:
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
    /// D6 §2.2：本地 spaceId <-> 账户 syncUuid 的映射层。`nil` 与 `spaceStateStore`
    /// 同款含义——「这个 controller 没有 Space 段」（单元测试，以及任何还没接线的
    /// 构造点）。**绝不给它一个内存默认值**：一个静默的进程内映射表会让每次启动重铸
    /// 一遍 syncUuid，账户里于是每台机器每次启动都多出一份重复 Space；`nil` 的失败
    /// 方向是「一条都不发布」，由 §9.3 的 `unmapped=<n>` 计数暴露。
    let spaceKeys: SpaceSyncMappingManager?

    private let localProfilesProvider: () -> [(profileId: String, displayName: String)]
    private let notifyChromium: () -> Void
    private let profileCreator: any LocalProfileCreating
    /// Shuts the settings/Space engine down and unhooks it. Injected as a closure
    /// (never a direct singleton reference) so the self-revoke tests do not reach
    /// the real `PhiChromiumCoordinator.shared`.
    private let retirePhiSync: () -> Void
    private let deviceKeyRotator: (any DeviceKeyRotating)?
    private let engineDefaults: UserDefaults
    private let spaceStateStore: (any PhiSpaceSyncStateStore)?

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
        /// teardown, a startup unlock that threw), both predicates were reset to
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

    init(manager: AccountKeyManager, approvals: DeviceApprovalService, profileKeys: ProfileKeyManager,
         spaceKeys: SpaceSyncMappingManager? = nil,
         localProfilesProvider: @escaping () -> [(profileId: String, displayName: String)],
         notifyChromium: @escaping () -> Void,
         profileCreator: any LocalProfileCreating = ProfileManager.shared,
         retirePhiSync: @escaping () -> Void = {},
         deviceKeyRotator: (any DeviceKeyRotating)? = nil,
         engineDefaults: UserDefaults = .standard,
         spaceStateStore: (any PhiSpaceSyncStateStore)? = nil) {
        self.manager = manager
        self.approvals = approvals
        self.profileKeys = profileKeys
        self.spaceKeys = spaceKeys
        self.localProfilesProvider = localProfilesProvider
        self.notifyChromium = notifyChromium
        self.profileCreator = profileCreator
        self.retirePhiSync = retirePhiSync
        self.deviceKeyRotator = deviceKeyRotator
        self.engineDefaults = engineDefaults
        self.spaceStateStore = spaceStateStore
    }

    /// Hot path: the bridge delegate calls this on every Chromium pull.
    /// Dictionary read only — no I/O, no crypto.
    func profileSyncInfo(forProfileId profileId: String) -> (uuid: String, passphrase: String)? {
        resolved[profileId]
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

    /// 主 actor 门面，形状照 `localProfileId(forGlobalUuid:)`（上面那两个）：
    /// `AccountPhiSpaceAccess` 经既有的 `controller` 引用读写 Space 映射，
    /// 引擎只经 `PhiSpaceLocalAccess` 碰到这里，不新增任何依赖。
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

    func mapSpace(_ spaceId: String, toSyncUuid uuid: String) throws {
        guard let spaceKeys else { throw SpaceSyncMappingError.mappingLayerUnavailable }
        try spaceKeys.map(spaceId: spaceId, toSyncUuid: uuid)
    }

    func removeSpaceMapping(forSpaceId spaceId: String) {
        spaceKeys?.removeMapping(forSpaceId: spaceId)
    }

    func allSpaceMappings() -> [String: String] {
        spaceKeys?.allMappings() ?? [:]
    }

    /// The pairing modal's only other exit. Order is a HARD requirement, not
    /// prudence (§3.3 step 2.0): a round parked in `getUpdates` still holds the
    /// domain key it fetched before the suspension, and the server does not check
    /// whether the committing device has been revoked. If the cleanup ran first,
    /// that round would resume, write the `phi.sync.*` cursor and the whole
    /// `sync.phiSpaces` table back, adopt the account's settings and every Space
    /// wholesale (both baselines were just erased), and then commit this machine's
    /// snapshot -- the exact opposite of what the confirmation promised.
    func removeThisDeviceFromSync() async throws {
        let deviceKeyId = try manager.deviceKeyProviderForTesting.deviceKeyId()
        try await profileKeys.revokeDevice(deviceKeyId: deviceKeyId)   // 409 -> lastActiveDevice, nothing below runs

        // 1. Retire the engine FIRST. `shutdown()` is nonisolated and synchronous,
        //    so it takes effect on return rather than being one more message to a
        //    reentrant actor.
        retirePhiSync()

        // 2. Keys. The device private key is ROTATED, not deleted: this Mac may
        //    hold other accounts' keys behind the same legacy item, and a revoked
        //    fingerprint can never be reused.
        do {
            try deviceKeyRotator?.rotateForCurrentAccount()
        } catch {
            // Non-fatal: the server has already revoked this device, so leaving the
            // account is done either way and there is nothing to roll back to. But
            // the Keychain may now hold a fingerprint the server refuses, and the
            // next join would 409 `device_revoked` -- so this never goes unlogged.
            AppLogWarn("[phi-sync] device key rotation failed (\(PhiSyncLog.describe(error)))")
        }
        manager.discardARK()

        // 3. Mappings, through the store -- never a direct AccountUserDefaults write.
        profileKeys.removeAllMappings()
        // D6 §2.3: the Space identity table goes with it. Order matters only in
        // one direction -- both tables must be gone before step 4 wipes the
        // cursor table, or a round that somehow survived would resolve a uuid
        // whose cursor no longer exists.
        spaceKeys?.removeAllMappings()

        // 4. Engine state. `phi.sync.cursorAccount` is deliberately kept: it is
        //    not a cursor, and dropping it would make the next build report a
        //    phantom account switch. Writing the Space table through the store
        //    directly is legal here precisely BECAUSE step 1 already shut the
        //    engine down -- `PhiSpaceSyncState`'s documented "there is no engine"
        //    exception to the single-writer rule, not a bypass of it. The facade's
        //    main-actor caches are refreshed by hand for the same reason: nothing
        //    else will push them back, and stale ones keep the departed account's
        //    hidden/soft-deleted Spaces hidden and keep refusing profile deletions
        //    until the next launch.
        for key in PhiSyncEngine.stateKeys { engineDefaults.removeObject(forKey: key) }
        spaceStateStore?.save(PhiSpaceSyncTable())
        PhiSpaceSyncState.shared.refreshCaches(from: PhiSpaceSyncTable())

        // 5. Resolved cache + both predicates, and the join flag. The `.cleared`
        //    announcement `clearResolved()` posts does take the gate's window down
        //    (`ProfilePairingGate`'s `.cleared` branch), but `.cleared` may never
        //    retire `sync.joinPairingPending` -- only a `.measured` pass may, and
        //    no measured pass will ever run again on this device -- so the flag is
        //    retired here by hand.
        clearResolved()
        ProfilePairingGate.joinPairingPending = false

        // Browsing data is untouched on purpose: LocalStore.sqlite and both
        // per-Space theme maps stay exactly as they are.
        AppLogInfo("[phi-sync] this device left the account's sync")
    }

    /// Startup/login entry: unlock without UI, then resolve mappings and ping.
    /// `.needsJoin` / `.notSignedIn` leave the cache empty — the Devices pane
    /// remains the place where joining/bootstrap UI happens.
    ///
    /// Any outcome other than `.unlocked` (including a thrown, possibly
    /// transient, failure) CLEARS the cache rather than leaving it standing.
    /// This direction is deliberately the opposite of `resolveMappings()`'s
    /// transient handling: here the unknown state fails *closed* (Chromium
    /// pulls nil and the sync gate shuts), which is always safe. In
    /// `resolveMappings()` the same uncertainty would fail *open* — minting a
    /// fresh UUID over a live mapping — so there it must be preserved instead.
    func silentUnlockAndResolve() async {
        let result: UnlockResult
        do {
            result = try await manager.unlockAtStartup()
        } catch {
            clearResolved()  // transient (offline etc.) — a later trigger retries
            return
        }
        guard result == .unlocked else {
            clearResolved()
            return
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
    /// straight after), and the gate dismisses only from
    /// `.phiProfileMappingsDidResolve`. Staying silent would leave the browser
    /// blocked behind a modal with nothing left to pair.
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
        if wasPopulated { notifyChromium() }
        announceMappingsResolved(.cleared)
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
    func resolveMappings() async {
        var next: [String: (uuid: String, passphrase: String)] = [:]
        let locals = localProfilesProvider()
        var unmappedLocals: [(profileId: String, displayName: String)] = []
        var hasUnknownLocal = false
        for local in locals {
            do {
                if let rec = try await profileKeys.resolvedRecord(forLocalProfile: local.profileId) {
                    next[local.profileId] = (rec.uuid, rec.passphrase)
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
                    unmappedLocals.append(local)
                }
            } catch {
                hasUnknownLocal = true
                AppLogInfo("[phi-sync-probe] unknown(transient) profile=\(local.profileId)")
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
        } catch {
            // Unknown remote set (offline / 5xx / 401 / still locked). Hold the
            // previous answer -- NEVER flip an app-modal gate true on a blip --
            // and still announce, or the gate and the Space gate miss a state
            // update until the next trigger. `.held`, because the predicates that
            // ride along were not measured here: reading them as an answer is how
            // one flap retires a pending join for good.
            resolved.merge(next) { _, new in new }
            if !resolved.isEmpty { notifyChromium() }
            announceMappingsResolved(.held)
            return
        }

        if !hasUnknownLocal {
            let claimed = Set(next.values.map { $0.uuid })
            let unclaimed = remoteUuids.subtracting(claimed)
            if unclaimed.isEmpty {
                // First device (or all remotes already claimed): register the rest.
                for local in unmappedLocals {
                    // `alreadyMapped` cannot normally reach here (only unmapped
                    // locals are in this list); if it does, skipping is correct
                    // — same handling as any other transient registration miss.
                    if let rec = try? await profileKeys.registerLocalProfile(
                        profileId: local.profileId, displayName: local.displayName) {
                        next[local.profileId] = (rec.uuid, rec.passphrase)
                        probeResolve("register", profileId: local.profileId, uuid: rec.uuid, passphrase: rec.passphrase)
                    }
                }
            } else if unclaimed.count == 1, unmappedLocals.count == 1 {
                if let uuid = unclaimed.first,
                   let rec = try? await profileKeys.adoptRemoteProfile(
                    uuid: uuid, forLocalProfile: unmappedLocals[0].profileId) {
                    next[unmappedLocals[0].profileId] = (rec.uuid, rec.passphrase)
                    probeResolve("adopt", profileId: unmappedLocals[0].profileId, uuid: rec.uuid, passphrase: rec.passphrase)
                }
            }
        }

        // Monotonic within a signed-in session: merge rather than replace, so a
        // partial pass can never erase a previously-good entry. The cache is
        // fully cleared only by `clearResolved()` (lock / sign-out / switch).
        resolved.merge(next) { _, new in new }
        // Set by the one branch that assigns the predicates, so the announcement's
        // marker follows the assignment itself rather than a re-derived condition.
        var outcome = MappingsOutcome.held
        if hasUnknownLocal {
            // Undecidable this pass; hold both predicates.
        } else {
            let claimedAfter = Set(next.values.map { $0.uuid })
            let stillUnmapped = locals.filter { next[$0.profileId] == nil }
            let stillUnclaimed = remoteUuids.subtracting(claimedAfter)
            needsPairing = !stillUnmapped.isEmpty || !stillUnclaimed.isEmpty
            needsPairingActionable = !stillUnmapped.isEmpty
                || !stillUnclaimed.subtracting(undecryptableRemoteUuids).isEmpty
            outcome = .measured
        }
        AppLogInfo("[phi-sync-probe] resolved=\(resolved.count) needsPairing=\(needsPairing) actionable=\(needsPairingActionable) outcome=\(outcome.rawValue)")
        if !resolved.isEmpty { notifyChromium() }
        announceMappingsResolved(outcome)
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
    func createLocalProfileAndAdopt(uuid: String, displayName: String) async throws -> String {
        let profileId: String
        if let pending = reusablePendingProfile(forUuid: uuid) {
            // A previous attempt already made a profile for exactly this uuid and
            // only the adopt failed. Re-adopt onto it; creating a second one is
            // how one network blip becomes a permanent empty duplicate.
            profileId = pending
        } else {
            let name = uniqueDisplayName(basedOn: displayName)
            guard let created = await profileCreator.createProfile(displayName: name) else {
                throw ProfileKeyManagerError.badEnvelope
            }
            // Recorded BEFORE the adopt, because the adopt is the step that can
            // throw and the profile already exists on disk by now.
            pendingCreatedProfiles[uuid] = created
            profileId = created
        }
        // The create is this round's only suspension, and `$profiles` runs a
        // `resolveMappings()` pass inside it whose 1:1 branch may have claimed
        // this very uuid onto another local. Adopting anyway would leave two
        // locals on one uuid.
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
        pendingCreatedProfiles[uuid] = nil
        return profileId
    }

    /// The suffix is decided by a PRE-CHECK, never by probing the return value:
    /// `createProfile` returns nil for three different reasons (empty or
    /// duplicate name, no bridge, bridge-side failure), so "nil means duplicate,
    /// try the next suffix" turns a missing bridge into unbounded probing.
    private func uniqueDisplayName(basedOn raw: String) -> String {
        let base = raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? NSLocalizedString("Profile", comment: "Fallback name for an account profile registered with no name")
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
    func ensureLocalProfilesForAccount() async -> ProfileRefreshOutcome {
        // Same gate as the Space section (§3.5), and deliberately NOT "is the
        // modal on screen": setting the flag and presenting the modal are two
        // events with a window between them, and a relaunch mid-pairing has
        // another one.
        //
        // `.skipped`, not `.failed`: §11 defines a gate-shut round as
        // `profile_refresh=skipped` and says in so many words that it is 不是失败.
        // Folding it into `.failed` would misreport the counter AND make the
        // engine treat a deliberate no-op as a retryable error.
        guard !ProfilePairingGate.joinPairingPending else {
            return await finishRefresh(.skipped, created: 0, skipped: 0)
        }
        let accountUuids: Set<String>
        do {
            accountUuids = try await profileKeys.accountProfileUuids()
        } catch {
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
        for uuid in missing {
            guard created < Self.maxAutoCreatesPerRound else { skipped += 1; continue }
            let remote: RemoteProfile
            do { remote = try await profileKeys.remoteProfile(uuid: uuid) } catch {
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
                if (try? await profileKeys.adoptRemoteProfile(uuid: uuid, forLocalProfile: twin.profileId)) != nil {
                    created += 1
                } else { skipped += 1 }
                continue
            }
            do {
                _ = try await createLocalProfileAndAdopt(uuid: uuid, displayName: name)
                created += 1
            } catch {
                AppLogInfo("[phi-sync] auto-create failed uuid=\(String(uuid.prefix(8))) (\(PhiSyncLog.describe(error)))")
                skipped += 1
            }
        }
        return await finishRefresh(created > 0 ? .changed : .unchanged, created: created, skipped: skipped)
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

    /// Temporary M2-5 diagnostic (issue ②, Needs-passphrase): records which key
    /// a profile resolved to, tagged by source, so a delivered passphrase can be
    /// compared across sessions — a changed hash for the same uuid is the
    /// envelope/keybag key desync we're hunting. Logs only a short SHA-256
    /// prefix, never the passphrase itself. Remove once ② is root-caused.
    ///
    /// R12: the account-global uuid is truncated to 8 characters, like every
    /// other uuid / tag hash this milestone logs. `AppLogInfo` goes to the
    /// CocoaLumberjack FILE logger, which is the artifact support asks users to
    /// upload, and "永不记录 profile_uuid 全串" is a constraint on that file.
    private func probeResolve(_ source: String, profileId: String, uuid: String, passphrase: String) {
        let ppHash = SHA256.hash(data: Data(passphrase.utf8)).prefix(6)
            .map { String(format: "%02x", $0) }.joined()
        AppLogInfo("[phi-sync-probe] resolve source=\(source) profile=\(profileId) uuid=\(String(uuid.prefix(8))) ppHash=\(ppHash)")
    }
}

import CryptoKit
import Foundation

/// The engine's view of the domain key. `PhiDomainKeyManager` is a concrete final class with
/// no seam of its own, so the abstraction lives here — the same shape as
/// `protocol KeyEnvelopeAPI` / `extension KeyEnvelopeAPIClient: KeyEnvelopeAPI {}`.
protocol PhiDomainKeyProviding: AnyObject {
    func domainKey() async throws -> SymmetricKey
}

extension PhiDomainKeyManager: PhiDomainKeyProviding {}

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
actor PhiSyncEngine {
    // MARK: - Persisted state
    //
    // All account-scoped: a sign-out or account switch must call `resetSyncState()`, otherwise
    // account A's progress marker and entity version get replayed against account B.

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

    static let stateKeys = [entityIdStateKey, versionStateKey, storeBirthdayStateKey,
                            markerStateKey, lastEntityStateKey, tombstoneRoundsStateKey,
                            hasAdoptedStateKey]

    /// GetUpdates pages drained in one pull before giving up until the next round. The server
    /// caps its own batch size; this only stops a pathological `changes_remaining` from
    /// spinning forever.
    private static let maxPullPages = 16

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
    private let deviceKeyId: String
    private let settings: [SyncableSetting]
    private let now: () -> Int64

    /// Set around `SyncableSettings.apply` so a local-change notification raised by the engine's
    /// own write is not mistaken for a user edit. The load-bearing echo suppression is the
    /// `<key>.phiSyncTs` / `<key>.phiSyncVal` sidecars `apply` maintains; this flag only closes
    /// the window while the write is in flight.
    private var isApplyingRemote = false

    /// Tail of the round chain. Each public entry point appends its round to this task and
    /// awaits it, so a round that suspends in `getUpdates` or `commit` still finishes before
    /// the next one starts. Only the public entry points enqueue: the internal `pull` -> `push`
    /// and conflict `push` -> `pull` -> `push` calls run inside an already-queued round and
    /// would deadlock if they queued again.
    private var roundQueue: Task<Void, Never>?

    /// What one queued round does. An enum rather than a closure so the body stays
    /// actor-isolated and needs no `@Sendable` gymnastics.
    private enum Round {
        case pull
        case push
        case localChange
    }

    init(domainKeys: any PhiDomainKeyProviding,
         client: PhiSyncProtocolClient,
         defaults: UserDefaults,
         deviceKeyId: String,
         settings: [SyncableSetting] = SyncableSettings.all,
         now: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.domainKeys = domainKeys
        self.client = client
        self.defaults = defaults
        self.deviceKeyId = deviceKeyId
        self.settings = settings
        self.now = now
    }

    // MARK: - Public surface

    /// GetUpdates -> decrypt -> merge -> apply, then publish anything the merge left the
    /// server behind on. Never throws: a failed round is logged and retried by the scheduler.
    func pullOnce() async {
        await serialized(.pull)
    }

    /// Snapshot -> encrypt -> Commit, with one pull-and-retry on CONFLICT.
    func pushLocalSettings() async {
        await serialized(.push)
    }

    /// Entry point for the debounced `UserDefaults.didChangeNotification` observer.
    func handleLocalDefaultsChange() async {
        await serialized(.localChange)
    }

    /// Drops every account-scoped cursor, `hasAdopted` included, so the next account's entity
    /// is adopted rather than merged against the previous account's timestamps. Called on
    /// sign-out / account switch, and by the engine itself when the server reports
    /// NOT_MY_BIRTHDAY.
    ///
    /// Deliberately synchronous and *not* queued: a sign-out must take effect immediately
    /// rather than behind an in-flight network round. It runs to completion between the
    /// suspension points of any round, so it never tears a half-written cursor.
    func resetSyncState() {
        for key in Self.stateKeys { defaults.removeObject(forKey: key) }
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
        switch round {
        case .pull:
            _ = await pull(retryOnBirthday: true, thenPush: true)
        case .push:
            await push(retryOnConflict: true, allowInitialPull: true)
        case .localChange:
            guard !isApplyingRemote else { return }
            await push(retryOnConflict: true, allowInitialPull: true)
        }
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

    /// Returns whether the round completed. The caller needs that: a first-ever push may only
    /// fall back to a `version = 0` create once it is sure the account holds nothing.
    private func pull(retryOnBirthday: Bool, thenPush: Bool) async -> Bool {
        let key: SymmetricKey
        do {
            key = try await domainKeys.domainKey()
        } catch {
            AppLogWarn("[phi-sync] pull skipped: domain key unavailable (\(error))")
            return false
        }

        // A pull with no marker replays the whole type, so "the entity was not in the response"
        // is only evidence of absence when we started from scratch and drained every page.
        let startedFromScratch = storedMarker == nil
        var view = RemoteView.absent
        var drained = false
        do {
            var marker = storedMarker
            var page = 0
            var more = true
            while more, page < Self.maxPullPages {
                let response = try await client.getUpdates(marker: marker, storeBirthday: storedBirthday)
                storedBirthday = response.storeBirthday
                marker = response.newMarker
                storedMarker = marker

                for entity in response.entities where entity.clientTagHash == PhiSyncEntity.clientTagHash {
                    if !entity.entityId.isEmpty { storedEntityId = entity.entityId }
                    storedVersion = entity.version
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
                        AppLogError("[phi-sync] cannot open remote entity version=\(entity.version) ciphertext_bytes=\(entity.ciphertext.count) (\(error))")
                        view = .unusable(reason: .undecryptable)
                    }
                }
                more = response.changesRemaining
                page += 1
            }
            drained = !more
        } catch PhiSyncProtocolError.notMyBirthday {
            resetSyncState()
            guard retryOnBirthday else { return false }
            return await pull(retryOnBirthday: false, thenPush: thenPush)
        } catch {
            AppLogError("[phi-sync] pull failed device=\(deviceKeyId) (\(error))")
            return false
        }

        var mayPublish = true
        switch view {
        case .usable(let remote):
            tombstoneRounds = 0
            // Wholesale only until this device has settings history of its own — which is
            // `hasAdopted`, not "do we know which row they live in": a cursor dropped by the
            // tombstone heal or the full-replay branch below must not cost this device its
            // local timestamps. See `apply` and `hasAdopted`.
            apply(remote, adopt: !hasAdopted)
        case .unusable(let reason):
            // The server holds bytes under our client tag that this build cannot read. Not
            // applying them is only half the job: the trailing push must not run either,
            // because it would commit this device's snapshot against the id and version we
            // just harvested from that very entity and replace it for every other device —
            // including the keys of a newer client that this build does not understand.
            // Rewinding the marker makes the next round see the entity again, so a re-minted
            // domain key or a newer build heals this instead of it being terminal.
            storedMarker = nil
            // The baseline goes with the marker, and that is what makes the refusal durable
            // rather than a one-round suppression. `push`'s guard reads "an entity id with no
            // baseline" as "the server holds bytes this device has not read"; a device that
            // had synced before would otherwise keep the baseline it decrypted at an older
            // version, and the next debounced local change — or the conflict retry, which
            // reaches `push` with `allowInitialPull: false` and never sees `mayPublish` —
            // would commit over the unreadable entity using the id and version harvested from
            // it right here. `storedEntityId` survives (the server always sends a non-empty
            // `id_string`: internal/chromiumsync/getupdates.go toSyncEntity, from the UUID
            // commit.go assigns on create), so `hasSyncedBefore` stays true and no
            // `version = 0` create can slip past the guard either. `apply` re-establishes the
            // baseline as soon as a pull can read the entity again.
            storedLastEntity = nil
            mayPublish = false
            noteUnusable(reason)
        case .absent:
            tombstoneRounds = 0
            if drained, startedFromScratch, storedEntityId != nil {
                // A full replay carried no settings entity: the row this device points at is
                // gone (a namespace change, a targeted delete, a partial restore). Keeping the
                // id would make every later commit an update the server answers with
                // INVALID_MESSAGE forever; dropping it lets the next push create instead.
                AppLogWarn("[phi-sync] full replay carried no settings entity; dropping the stale entity cursor")
                clearEntityCursor()
            }
        }

        // Publish whatever the merge left the server short of (a locally newer value, or a
        // registered key the remote entity did not carry). `push` decides by comparison, so a
        // pure remote apply commits nothing.
        if thenPush, mayPublish { await push(retryOnConflict: false, allowInitialPull: false) }
        return true
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
    }

    private func apply(_ remote: Phi_PhiSettingEntity, adopt: Bool) {
        // A device with no settings history has no timestamps to compare against: every key it
        // snapshots would be stamped `now` and beat the account's real edits. So the first pull
        // adopts the account's entity wholesale; later pulls merge field by field.
        let merged: Phi_PhiSettingEntity
        if adopt {
            merged = remote
        } else {
            let local = SyncableSettings.snapshot(defaults, now: now(), settings: settings)
            merged = SyncableSettings.merge(local: local, remote: remote)
        }

        isApplyingRemote = true
        SyncableSettings.apply(merged, to: defaults, settings: settings)
        isApplyingRemote = false

        // What the server holds, not what we now hold locally: `push` compares against this to
        // decide whether anything still needs publishing.
        storedLastEntity = remote
        // `apply` leaves a `<key>.phiSyncTs` sidecar behind for every key it wrote, so from
        // here on this device has timestamps a merge can compare — no later pull may adopt.
        hasAdopted = true
        AppLogInfo("[phi-sync] applied remote settings keys=\(merged.values.count)")
    }

    // MARK: - Push

    private func push(retryOnConflict: Bool, allowInitialPull: Bool) async {
        // A `version = 0` commit takes the server's ON CONFLICT (client_tag_hash) DO UPDATE
        // path, which overwrites whatever is there. A device that has never synced must
        // discover the account's entity first or it silently clobbers every other device.
        if allowInitialPull, !hasSyncedBefore {
            guard await pull(retryOnBirthday: true, thenPush: false) else {
                AppLogWarn("[phi-sync] first push aborted: the account's current settings could not be read")
                return
            }
        }

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
            AppLogWarn("[phi-sync] push skipped: domain key unavailable (\(error))")
            return
        }

        let last = storedLastEntity
        let local = SyncableSettings.snapshot(defaults, now: now(), settings: settings)
        // Merging against the last known server entity keeps keys this build does not know
        // about (a newer client's settings) instead of deleting them on every push.
        let outgoing = SyncableSettings.merge(local: local, remote: last ?? Phi_PhiSettingEntity())
        if let last, outgoing == last { return }

        var wrapper = Phi_PhiEntity()
        wrapper.setting = outgoing

        do {
            let ciphertext = try PhiEntityCodec.encrypt(wrapper, key: key)
            let outcome = try await client.commit(entityId: storedEntityId,
                                                  clientTagHash: PhiSyncEntity.clientTagHash,
                                                  ciphertext: ciphertext,
                                                  baseVersion: storedVersion ?? 0,
                                                  storeBirthday: storedBirthday)
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
                _ = await pull(retryOnBirthday: true, thenPush: false)
                await push(retryOnConflict: false, allowInitialPull: false)
            }
        } catch PhiSyncProtocolError.notMyBirthday {
            resetSyncState()
        } catch PhiSyncProtocolError.commitRejected(.invalidMessage) {
            // The server could not find the row this commit names: the update path returns
            // INVALID_MESSAGE on pgx.ErrNoRows and on a data_type mismatch
            // (internal/data/entities_write.go), and NOT_MY_BIRTHDAY never fires because the
            // account row — and with it store_birthday — is untouched. An incremental
            // GetUpdates cannot tell us either: it simply returns nothing. Without dropping the
            // cursor the device would send the same stale id and version forever and never sync
            // again. Reset everything (the marker included) so the next round replays the type
            // from scratch and either re-discovers the entity or creates it through the
            // client_tag_hash unique index.
            AppLogWarn("[phi-sync] commit rejected as INVALID_MESSAGE; dropping the local sync cursor so the next round rediscovers the entity")
            resetSyncState()
        } catch {
            AppLogError("[phi-sync] push failed device=\(deviceKeyId) (\(error))")
        }
    }

    // MARK: - Persisted state accessors

    /// True once this device knows *which row* the account's settings live in — either it has
    /// seen the entity or it has committed its own. Answers "may a `version = 0` create go
    /// out?", nothing else; `clearEntityCursor()` makes it false again. The merge-vs-adopt
    /// decision deliberately does not read it — that is `hasAdopted`.
    private var hasSyncedBefore: Bool { storedEntityId != nil || storedLastEntity != nil }

    /// True once this device has settings history for the account: a pull applied the account's
    /// entity, or this device committed a snapshot of its own. Either way `<key>.phiSyncTs`
    /// sidecars now exist for the registered keys, which is what makes a field-level merge
    /// meaningful — so this, not `hasSyncedBefore`, is what gates the wholesale adopt in
    /// `apply`. The two used to be the same predicate, and the coupling was a silent data
    /// loss: `clearEntityCursor()` (the tombstone heal, the full-replay branch) forgets which
    /// row the settings live in, and the next readable entity was then adopted wholesale over
    /// local edits whose debounced push had not run yet.
    ///
    /// Not derived from the sidecars themselves: those sit next to the preference keys and are
    /// not account-scoped, so they outlive `resetSyncState()` and would stop a device from
    /// adopting the settings of an account it has just switched to. Only `resetSyncState()`
    /// clears this.
    ///
    /// One known window, accepted rather than closed. The two predicates disagree the other way
    /// when a device's only sight of the entity was `.unusable`: the pull records
    /// `storedEntityId` from that entity before dropping the baseline, so `hasSyncedBefore` is
    /// true while `hasAdopted` is false, and `push` then returns at its "an entity id with no
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
            guard newValue else { return defaults.removeObject(forKey: Self.hasAdoptedStateKey) }
            defaults.set(true, forKey: Self.hasAdoptedStateKey)
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

    private var storedEntityId: String? {
        get { defaults.string(forKey: Self.entityIdStateKey) }
        set {
            guard let newValue else { return defaults.removeObject(forKey: Self.entityIdStateKey) }
            defaults.set(newValue, forKey: Self.entityIdStateKey)
        }
    }

    private var storedVersion: Int64? {
        get { (defaults.object(forKey: Self.versionStateKey) as? NSNumber)?.int64Value }
        set {
            guard let newValue else { return defaults.removeObject(forKey: Self.versionStateKey) }
            defaults.set(NSNumber(value: newValue), forKey: Self.versionStateKey)
        }
    }

    private var storedBirthday: String {
        get { defaults.string(forKey: Self.storeBirthdayStateKey) ?? "" }
        set { defaults.set(newValue, forKey: Self.storeBirthdayStateKey) }
    }

    private var storedMarker: Data? {
        get { defaults.data(forKey: Self.markerStateKey) }
        set {
            guard let newValue, !newValue.isEmpty else { return defaults.removeObject(forKey: Self.markerStateKey) }
            defaults.set(newValue, forKey: Self.markerStateKey)
        }
    }

    /// Consecutive pulls that found the account's settings row tombstoned. Zero is stored as
    /// "absent" so `stateKeys` stays a clean "nothing persisted" set after `resetSyncState()`.
    private var tombstoneRounds: Int {
        get { defaults.integer(forKey: Self.tombstoneRoundsStateKey) }
        set {
            guard newValue > 0 else { return defaults.removeObject(forKey: Self.tombstoneRoundsStateKey) }
            defaults.set(newValue, forKey: Self.tombstoneRoundsStateKey)
        }
    }

    private var storedLastEntity: Phi_PhiSettingEntity? {
        get {
            guard let bytes = defaults.data(forKey: Self.lastEntityStateKey) else { return nil }
            return try? Phi_PhiSettingEntity(serializedBytes: bytes)
        }
        set {
            guard let newValue, let bytes = try? newValue.serializedData() else {
                return defaults.removeObject(forKey: Self.lastEntityStateKey)
            }
            defaults.set(bytes, forKey: Self.lastEntityStateKey)
        }
    }
}

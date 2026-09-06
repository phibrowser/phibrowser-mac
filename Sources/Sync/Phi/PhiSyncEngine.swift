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
/// An `actor` so the debounced local-change push, the periodic pull, the foreground pull and
/// the conflict retry cannot interleave: they all mutate the same persisted cursor and the
/// same `UserDefaults` snapshot. `PhiDomainKeyManager` is only ever touched from in here.
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

    static let stateKeys = [entityIdStateKey, versionStateKey, storeBirthdayStateKey,
                            markerStateKey, lastEntityStateKey]

    /// GetUpdates pages drained in one pull before giving up until the next round. The server
    /// caps its own batch size; this only stops a pathological `changes_remaining` from
    /// spinning forever.
    private static let maxPullPages = 16

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
        _ = await pull(retryOnBirthday: true, thenPush: true)
    }

    /// Snapshot -> encrypt -> Commit, with one pull-and-retry on CONFLICT.
    func pushLocalSettings() async {
        await push(retryOnConflict: true, allowInitialPull: true)
    }

    /// Entry point for the debounced `UserDefaults.didChangeNotification` observer.
    func handleLocalDefaultsChange() async {
        guard !isApplyingRemote else { return }
        await pushLocalSettings()
    }

    /// Drops every account-scoped cursor. Called on sign-out / account switch, and by the
    /// engine itself when the server reports NOT_MY_BIRTHDAY.
    func resetSyncState() {
        for key in Self.stateKeys { defaults.removeObject(forKey: key) }
    }

    // MARK: - Pull

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

        // Captured before the loop: the loop itself records the entity id, which would make
        // `hasSyncedBefore` true by the time the merge decision is taken.
        let adoptRemote = !hasSyncedBefore
        var remote: Phi_PhiSettingEntity?
        var sawEntity = false
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
                    sawEntity = true
                    guard !entity.deleted else {
                        // A tombstone from another device: nothing to apply, but the version is
                        // still the base the next commit has to build on.
                        remote = nil
                        continue
                    }
                    do {
                        let decoded = try PhiEntityCodec.decrypt(entity.ciphertext, key: key)
                        guard case .setting(let setting)? = decoded.kind else {
                            AppLogWarn("[phi-sync] remote entity carries no settings payload; ignoring")
                            remote = nil
                            continue
                        }
                        remote = setting
                    } catch {
                        // Wrong key or corrupt bytes. Never apply, never claim it as our
                        // baseline — the recorded id/version still let a later local edit
                        // replace it rather than leaving this device stuck forever.
                        AppLogError("[phi-sync] cannot open remote entity version=\(entity.version) ciphertext_bytes=\(entity.ciphertext.count) (\(error))")
                        remote = nil
                    }
                }
                more = response.changesRemaining
                page += 1
            }
        } catch PhiSyncProtocolError.notMyBirthday {
            resetSyncState()
            guard retryOnBirthday else { return false }
            return await pull(retryOnBirthday: false, thenPush: thenPush)
        } catch {
            AppLogError("[phi-sync] pull failed device=\(deviceKeyId) (\(error))")
            return false
        }

        if let remote {
            apply(remote, adopt: adoptRemote)
        } else if sawEntity {
            AppLogInfo("[phi-sync] pull saw the settings entity but had nothing to apply")
        }

        // Publish whatever the merge left the server short of (a locally newer value, or a
        // registered key the remote entity did not carry). `push` decides by comparison, so a
        // pure remote apply commits nothing.
        if thenPush { await push(retryOnConflict: false, allowInitialPull: false) }
        return true
    }

    private func apply(_ remote: Phi_PhiSettingEntity, adopt: Bool) {
        // A device that has never synced has no timestamp history to compare against: every
        // key it snapshots would be stamped `now` and beat the account's real edits. So the
        // first pull adopts the account's entity wholesale; later pulls merge field by field.
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
        } catch {
            AppLogError("[phi-sync] push failed device=\(deviceKeyId) (\(error))")
        }
    }

    // MARK: - Persisted state accessors

    /// True once this device has either seen the account's entity or committed its own.
    private var hasSyncedBefore: Bool { storedEntityId != nil || storedLastEntity != nil }

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

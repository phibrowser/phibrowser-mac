import CryptoKit
import Foundation
import Security

/// `alreadyMapped` is a *refusal to mint*, not a failure: it means the caller
/// asked to register a brand-new global UUID for a local profile that already
/// carries a mapping. Minting there would orphan the account's real envelope
/// and permanently diverge the two devices, so it is rejected at the lowest
/// layer regardless of what the caller believed about the mapping state.
enum ProfileKeyManagerError: Error, Equatable { case notUnlocked, badEnvelope, alreadyMapped }

struct ProfileKeyRecord: Equatable {
    let uuid: String
    let passphrase: String
    let name: String
}

struct RemoteProfile: Equatable {
    let uuid: String
    let name: String?   // nil when the envelope cannot be decrypted with the current ARK
}

/// Persists the local-profile-id -> account-global profile UUID mapping.
protocol ProfileSyncMappingStore {
    func globalUuid(forProfileId profileId: String) -> String?
    func setGlobalUuid(_ uuid: String, forProfileId profileId: String)
    func allMappings() -> [String: String]
    /// Drops ONE dead entry: the local profile behind it was deleted, so the
    /// reverse lookup would otherwise hand the sync layer a profileId that no
    /// longer exists and every landing would throw forever (§6.2 A0).
    func removeMapping(forProfileId profileId: String)
    /// Wipes the whole table: self-revoke (§3.3). Never a partial write, and
    /// never done by writing `AccountUserDefaults` behind the store's back.
    func removeAllMappings()
}

/// Manages per-profile Chromium keys under the ARK: generates and escrows a
/// 32-byte key per profile (sealed with the ARK, display name inside the
/// envelope), adopts keys registered by other devices, and answers
/// "what passphrase does this local profile use" for the bridge.
final class ProfileKeyManager {
    private let api: KeyEnvelopeAPI
    private let keyManager: AccountKeyManager
    private let mappingStore: ProfileSyncMappingStore

    init(api: KeyEnvelopeAPI, keyManager: AccountKeyManager, mappingStore: ProfileSyncMappingStore) {
        self.api = api
        self.keyManager = keyManager
        self.mappingStore = mappingStore
    }

    static func passphrase(fromKey key: Data) -> String {
        key.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Envelope codec ({"v":1,"key":base64,"name":string} sealed with the ARK)

    static func sealProfilePayload(key: Data, name: String, ark: SymmetricKey) throws -> Data {
        let payload = try JSONSerialization.data(withJSONObject: [
            "v": 1, "key": key.base64EncodedString(), "name": name])
        return try PhiKeyCrypto.sealWithSymmetric(payload, key: ark)
    }

    static func openProfilePayload(_ envelope: Data, ark: SymmetricKey) throws -> (key: Data, name: String) {
        let plain = try PhiKeyCrypto.openWithSymmetric(envelope, key: ark)
        guard let obj = try? JSONSerialization.jsonObject(with: plain) as? [String: Any],
              obj["v"] as? Int == 1,
              let keyB64 = obj["key"] as? String,
              let key = Data(base64Encoded: keyB64) else {
            throw ProfileKeyManagerError.badEnvelope
        }
        return (key, obj["name"] as? String ?? "")
    }

    // MARK: - Flows

    /// The global UUID this local profile is already mapped to, nil when it has
    /// never been registered or adopted on this device. Exposed so callers (the
    /// pairing UI) can offer "register as new" only for genuinely unmapped
    /// locals rather than discovering the refusal via `alreadyMapped`.
    func mappedGlobalUuid(forProfileId profileId: String) -> String? {
        mappingStore.globalUuid(forProfileId: profileId)
    }

    /// First registration of a local profile: mint a global UUID, generate the
    /// key, seal, and PUT. A 409 (concurrent registration of the same uuid)
    /// adopts the winner's envelope instead.
    ///
    /// Refuses with `alreadyMapped` when this local profile already has a
    /// mapping. This is the last line of defence for C-1: a caller that
    /// mistook a transient lookup failure for "no mapping" would otherwise
    /// mint a fresh UUID here, silently abandoning the account's existing
    /// envelope for this profile.
    func registerLocalProfile(profileId: String, displayName: String) async throws -> ProfileKeyRecord {
        guard mappingStore.globalUuid(forProfileId: profileId) == nil else {
            throw ProfileKeyManagerError.alreadyMapped
        }
        guard let ark = keyManager.currentARK else { throw ProfileKeyManagerError.notUnlocked }
        var key = Data(count: 32)
        let status = key.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        guard status == errSecSuccess else { throw AccountKeyError.randomGenerationFailed(status) }
        let uuid = UUID().uuidString.lowercased()
        let envelope = try Self.sealProfilePayload(key: key, name: displayName, ark: ark)
        let created = try await api.putProfileKey(uuid: uuid, envelope: envelope)
        if !created {
            return try await adoptRemoteProfile(uuid: uuid, forLocalProfile: profileId)
        }
        mappingStore.setGlobalUuid(uuid, forProfileId: profileId)
        return ProfileKeyRecord(uuid: uuid, passphrase: Self.passphrase(fromKey: key), name: displayName)
    }

    /// Maps a local profile onto an already-registered account profile and
    /// decrypts its key.
    func adoptRemoteProfile(uuid: String, forLocalProfile profileId: String) async throws -> ProfileKeyRecord {
        guard let ark = keyManager.currentARK else { throw ProfileKeyManagerError.notUnlocked }
        guard let dto = try await api.getProfileKey(uuid: uuid) else { throw ProfileKeyManagerError.badEnvelope }
        let (key, name) = try Self.openProfilePayload(dto.profileKeyEnvelope, ark: ark)
        mappingStore.setGlobalUuid(uuid, forProfileId: profileId)
        return ProfileKeyRecord(uuid: uuid, passphrase: Self.passphrase(fromKey: key), name: name)
    }

    /// Returns the record for an already-mapped local profile, nil when unmapped.
    func resolvedRecord(forLocalProfile profileId: String) async throws -> ProfileKeyRecord? {
        guard let uuid = mappingStore.globalUuid(forProfileId: profileId) else { return nil }
        guard let ark = keyManager.currentARK else { throw ProfileKeyManagerError.notUnlocked }
        guard let dto = try await api.getProfileKey(uuid: uuid) else { return nil }
        let (key, name) = try Self.openProfilePayload(dto.profileKeyEnvelope, ark: ark)
        return ProfileKeyRecord(uuid: uuid, passphrase: Self.passphrase(fromKey: key), name: name)
    }

    /// All profiles registered on the account, names decrypted where possible
    /// (pairing UI input).
    func accountProfiles() async throws -> [RemoteProfile] {
        guard let ark = keyManager.currentARK else { throw ProfileKeyManagerError.notUnlocked }
        var out: [RemoteProfile] = []
        for summary in try await api.listProfiles() {
            if let dto = try await api.getProfileKey(uuid: summary.profileUuid),
               let (_, name) = try? Self.openProfilePayload(dto.profileKeyEnvelope, ark: ark) {
                out.append(RemoteProfile(uuid: summary.profileUuid, name: name))
            } else {
                out.append(RemoteProfile(uuid: summary.profileUuid, name: nil))
            }
        }
        return out
    }

    /// Inbound translation for the sync layer: which LOCAL profile carries this
    /// account-global uuid. Built on the PERSISTED mapping, deliberately not on
    /// `SyncKeyController.resolved` -- that one holds live passphrase material,
    /// only covers profiles whose envelope opens right now, and is wiped whole
    /// by `clearResolved()` on lock / sign-out, which would cost the Space
    /// engine every binding the instant the ARK goes away.
    ///
    /// Two locals on one uuid is a state M2 does not intend to produce; when it
    /// happens the smallest profileId wins so every device resolves it the same
    /// way, and it is logged.
    func localProfileId(forGlobalUuid uuid: String) -> String? {
        let matches = mappingStore.allMappings()
            .filter { $0.value == uuid }
            .keys
            .sorted()
        if matches.count > 1 {
            AppLogWarn("[phi-sync] \(matches.count) local profiles map to one account profile; taking the lexicographically smallest")
        }
        return matches.first
    }

    /// The account's profile uuids, and nothing else. `accountProfiles()` pays
    /// one envelope GET per uuid to decrypt display names; the callers that only
    /// need the SET of uuids (`resolveMappings()`, §3.6's per-round refresh) run
    /// every 60 s and never read a name, so they use this instead.
    ///
    /// The ARK guard belongs HERE, not at the call sites: `listProfiles` is a
    /// plain bearer-token call that never touches the ARK, so without it a
    /// locked device would get a successful list and then fail on every single
    /// envelope, turning "skipped because locked" into "ran and changed
    /// nothing".
    func accountProfileUuids() async throws -> Set<String> {
        guard keyManager.currentARK != nil else { throw ProfileKeyManagerError.notUnlocked }
        return Set(try await api.listProfiles().map(\.profileUuid))
    }

    /// One account profile with its registered display name, or `name == nil`
    /// when the envelope does not open under the current ARK. Same decoding as
    /// `accountProfiles()`, for one uuid.
    func remoteProfile(uuid: String) async throws -> RemoteProfile {
        guard let ark = keyManager.currentARK else { throw ProfileKeyManagerError.notUnlocked }
        guard let dto = try await api.getProfileKey(uuid: uuid) else {
            return RemoteProfile(uuid: uuid, name: nil)
        }
        guard let (_, name) = try? Self.openProfilePayload(dto.profileKeyEnvelope, ark: ark) else {
            return RemoteProfile(uuid: uuid, name: nil)
        }
        return RemoteProfile(uuid: uuid, name: name)
    }

    func removeMapping(forProfileId profileId: String) {
        mappingStore.removeMapping(forProfileId: profileId)
    }

    /// Self-revoke (§3.3): retire THIS device's row server-side. Throws
    /// `KeyAPIError.lastActiveDevice` on 409 -- the account would be left with no
    /// active device -- and the caller must then change nothing locally.
    func revokeDevice(deviceKeyId: String) async throws {
        try await api.revokeDevice(deviceKeyId: deviceKeyId)
    }

    /// Self-revoke (§3.3): the whole local-profile -> account-uuid table goes.
    func removeAllMappings() { mappingStore.removeAllMappings() }

    /// The whole persisted table, local profile id -> account uuid. §3.6 reads it
    /// to tell an unmapped local profile (adoptable) from a mapped one.
    func allMappings() -> [String: String] { mappingStore.allMappings() }

    /// The account uuids this device has already claimed. §3.6's "missing" set is
    /// the account's uuids minus these — deliberately built from the PERSISTED
    /// mapping, not from the live local profile list.
    func allMappedGlobalUuids() -> [String] { Array(mappingStore.allMappings().values) }
}

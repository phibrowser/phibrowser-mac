import CryptoKit
import Foundation
import Security

enum ProfileKeyManagerError: Error, Equatable { case notUnlocked, badEnvelope }

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

    /// First registration of a local profile: mint a global UUID, generate the
    /// key, seal, and PUT. A 409 (concurrent registration of the same uuid)
    /// adopts the winner's envelope instead.
    func registerLocalProfile(profileId: String, displayName: String) async throws -> ProfileKeyRecord {
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
}

import CryptoKit
import Foundation
import Security

/// Owns the account-wide PhiBrowser domain key: a single 32-byte AES-GCM key,
/// sibling of the per-profile keys, escrowed on the server sealed under the ARK
/// and never uploaded in the clear (zero-knowledge invariant).
///
/// Unlike `ProfileKeyManager` there is no local-id mapping — one key per account,
/// under the fixed domain `"phi"` — so the whole lifecycle is: GET; if absent
/// mint + seal + PUT; if the PUT loses the first-use race (409) re-GET and adopt
/// the winner, discarding the key generated here.
final class PhiDomainKeyManager {
    /// The one domain M3-1 uses. Matches the `{domain}` path segment of
    /// `/keys/v1/domains/{domain}` and the `phi` sync data type.
    static let domain = "phi"

    private let api: KeyEnvelopeAPI
    private let keyManager: AccountKeyManager
    private var cached: SymmetricKey?

    init(api: KeyEnvelopeAPI, keyManager: AccountKeyManager) {
        self.api = api
        self.keyManager = keyManager
    }

    /// The account's PhiBrowser domain key, minting and escrowing it on first use.
    /// Throws `ProfileKeyManagerError.notUnlocked` when the ARK is not available —
    /// a locked key layer must fail loudly rather than mint a key it cannot escrow.
    func domainKey() async throws -> SymmetricKey {
        if let cached { return cached }
        guard let ark = keyManager.currentARK else { throw ProfileKeyManagerError.notUnlocked }

        if let envelope = try await api.getDomainKey(domain: Self.domain) {
            return cache(try Self.unseal(envelope, ark: ark))
        }

        var key = Data(count: 32)
        let status = key.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        guard status == errSecSuccess else { throw AccountKeyError.randomGenerationFailed(status) }
        let envelope = try ProfileKeyManager.sealProfilePayload(key: key, name: Self.domain, ark: ark)
        if try await api.putDomainKey(domain: Self.domain, envelope: envelope) {
            return cache(key)
        }
        // Lost the race: another device escrowed first. Adopt its key and drop ours —
        // keeping the local one would encrypt data no other device could read.
        guard let winner = try await api.getDomainKey(domain: Self.domain) else {
            throw ProfileKeyManagerError.badEnvelope
        }
        return cache(try Self.unseal(winner, ark: ark))
    }

    /// Drops the cached key (sign-out, or an ARK change that invalidates it).
    func clear() { cached = nil }

    private func cache(_ raw: Data) -> SymmetricKey {
        let key = SymmetricKey(data: raw)
        cached = key
        return key
    }

    /// Reuses the per-profile envelope codec ({"v":1,"key":base64,"name":string}
    /// sealed with the ARK); `name` carries the domain and is not read back.
    private static func unseal(_ envelope: Data, ark: SymmetricKey) throws -> Data {
        try ProfileKeyManager.openProfilePayload(envelope, ark: ark).key
    }
}

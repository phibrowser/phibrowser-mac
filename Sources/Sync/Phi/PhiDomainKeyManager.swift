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
///
/// Isolation: `@MainActor`, like every other owner of the M2 key layer
/// (`SyncKeyController`, `KeyLayerViewModel`, `DevicesSettingViewModel`). That is not
/// decoration — it is the invariant that keeps `AccountKeyManager` main-actor-confined.
/// `PhiSyncEngine` is an `actor`, so without this annotation `domainKey()` would run on the
/// cooperative pool (SE-0338: a `nonisolated` async function does not inherit its caller's
/// executor) and would then read `AccountKeyManager.currentARK` — a plain `var` on a plain
/// class that the unlock/join/sign-out flows mutate on the main actor — and read-modify-write
/// `cached` concurrently with `PhiChromiumCoordinator.stopPhiSync()`'s `clear()`. Both are
/// races on refcounted values, i.e. a torn read or an over-release, not merely a stale key.
/// The engine already reaches this type through `await domainKeys.domainKey()`, so the
/// annotation costs one hop per round and nothing else; the network call inside suspends, so
/// the main actor is not held across it.
@MainActor
final class PhiDomainKeyManager {
    /// The one domain M3-1 uses. Matches the `{domain}` path segment of
    /// `/keys/v1/domains/{domain}` and the `phi` sync data type.
    static let domain = "phi"

    private let api: KeyEnvelopeAPI
    private let keyManager: AccountKeyManager
    /// The cached key together with a fingerprint of the ARK it was derived under. Tying the
    /// two means an account switch inside one process cannot keep serving the previous
    /// account's key: the fingerprint stops matching and the key is refetched.
    private var cached: (arkFingerprint: Data, key: SymmetricKey)?

    init(api: KeyEnvelopeAPI, keyManager: AccountKeyManager) {
        self.api = api
        self.keyManager = keyManager
    }

    /// The account's PhiBrowser domain key, minting and escrowing it on first use.
    /// Throws `ProfileKeyManagerError.notUnlocked` when the ARK is not available —
    /// a locked key layer must fail loudly rather than mint a key it cannot escrow.
    func domainKey() async throws -> SymmetricKey {
        guard let ark = keyManager.currentARK else { throw ProfileKeyManagerError.notUnlocked }
        let fingerprint = Self.fingerprint(of: ark)
        if let cached, cached.arkFingerprint == fingerprint { return cached.key }
        self.cached = nil

        if let envelope = try await api.getDomainKey(domain: Self.domain) {
            return cache(try Self.unseal(envelope, ark: ark), fingerprint: fingerprint)
        }

        var key = Data(count: 32)
        let status = key.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        guard status == errSecSuccess else { throw AccountKeyError.randomGenerationFailed(status) }
        let envelope = try ProfileKeyManager.sealProfilePayload(key: key, name: Self.domain, ark: ark)
        if try await api.putDomainKey(domain: Self.domain, envelope: envelope) {
            return cache(key, fingerprint: fingerprint)
        }
        // Lost the race: another device escrowed first. Adopt its key and drop ours —
        // keeping the local one would encrypt data no other device could read.
        guard let winner = try await api.getDomainKey(domain: Self.domain) else {
            throw ProfileKeyManagerError.badEnvelope
        }
        return cache(try Self.unseal(winner, ark: ark), fingerprint: fingerprint)
    }

    /// Drops the cached key (sign-out, or an ARK change that invalidates it).
    func clear() { cached = nil }

    private func cache(_ raw: Data, fingerprint: Data) -> SymmetricKey {
        let key = SymmetricKey(data: raw)
        cached = (fingerprint, key)
        return key
    }

    /// Identifies the ARK without keeping a copy of it: SHA-256 over the raw key bytes.
    private static func fingerprint(of ark: SymmetricKey) -> Data {
        Data(SHA256.hash(data: ark.withUnsafeBytes { Data($0) }))
    }

    /// Reuses the per-profile envelope codec ({"v":1,"key":base64,"name":string}
    /// sealed with the ARK); `name` carries the domain and is not read back.
    private static func unseal(_ envelope: Data, ark: SymmetricKey) throws -> Data {
        try ProfileKeyManager.openProfilePayload(envelope, ark: ark).key
    }
}

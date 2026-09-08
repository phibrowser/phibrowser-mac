import CryptoKit
import Foundation
import Security

enum DeviceKeyStoreError: Error { case keychainFailure(OSStatus) }

/// Keychain-backed storage for the device private key. Follows SharedAuthTokenStore's
/// data-protection pattern, but uses its own service/account and stays out of the
/// app group — the device private key is not shared with Sentinel. The plaintext key
/// only ever lives in the Keychain (system-encrypted) and in memory; it is never uploaded.
///
/// As of M3-2 the item is ACCOUNT-SCOPED. Before that there was one fixed item per Mac,
/// shared by every account that ever signed in; self-revoke has to be able to retire this
/// device's key for ONE account without stranding another account whose `account_devices`
/// row is still `active` and whose `ark_envelope` only that private key can open.
final class DeviceKeyStore {
    private let service: String
    private let account: String
    /// The pre-M3-2 fixed item. Read-only from here on: a MIGRATION SOURCE only,
    /// never written and never deleted.
    private static let legacyAccount = "device-x25519-v1"

    init(service: String = "com.phibrowser.sync.device-key", accountId: String?) {
        self.service = service
        self.account = accountId.map { "\(Self.legacyAccount):\($0)" } ?? Self.legacyAccount
    }

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecUseDataProtectionKeychain as String: true,
         kSecAttrSynchronizable as String: false]
    }

    private var legacyQuery: [String: Any] {
        var query = baseQuery
        query[kSecAttrAccount as String] = Self.legacyAccount
        return query
    }

    func loadOrCreatePrivateKey() throws -> Curve25519.KeyAgreement.PrivateKey {
        if let existing = try load(baseQuery) { return existing }
        // COPY the legacy key rather than minting a new one: device_key_id is the
        // public key's fingerprint, so regenerating turns a device that is already
        // registered into a stranger -- `getDeviceEnvelope` 404 -> `.needsJoin`.
        if account != Self.legacyAccount, let legacy = try load(legacyQuery) {
            try store(legacy.rawRepresentation)
            return legacy
        }
        let key = PhiKeyCrypto.generateDeviceKeyPair()
        do {
            try store(key.rawRepresentation)
            return key
        } catch DeviceKeyStoreError.keychainFailure(errSecDuplicateItem) {
            // Lost a first-registration race: another thread/process already wrote a
            // device key between our load() miss and this store() attempt. Return the
            // winner's key instead of failing, matching loadOrCreatePrivateKey's contract.
            guard let winner = try load(baseQuery) else {
                throw DeviceKeyStoreError.keychainFailure(errSecDuplicateItem)
            }
            return winner
        }
    }

    /// Self-revoke: ROTATE the current account's key in place. Never "delete and
    /// leave empty" -- the next read would copy the legacy key back, and the
    /// server never un-revokes an id (`internal/data/keys_devices.go:93-94`), so
    /// rejoining would fail forever. The new fingerprint is exactly what lets
    /// this Mac rejoin. The legacy item and every other account's item are
    /// untouched.
    func rotateForCurrentAccount() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw DeviceKeyStoreError.keychainFailure(status)
        }
        try store(PhiKeyCrypto.generateDeviceKeyPair().rawRepresentation)
    }

    func deviceKeyId() throws -> String {
        let key = try loadOrCreatePrivateKey()
        let digest = SHA256.hash(data: key.publicKey.rawRepresentation)
        let prefix = Data(digest.prefix(16))
        return prefix.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    func deleteForTesting() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw DeviceKeyStoreError.keychainFailure(status)
        }
    }

    private func load(_ query: [String: Any]) throws -> Curve25519.KeyAgreement.PrivateKey? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = out as? Data else {
            throw DeviceKeyStoreError.keychainFailure(status)
        }
        return try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data)
    }

    /// Writes only ever land on `baseQuery` -- the legacy item is a read-only
    /// migration source.
    private func store(_ raw: Data) throws {
        var attrs = baseQuery
        attrs[kSecValueData as String] = raw
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(attrs as CFDictionary, nil)
        guard status == errSecSuccess else { throw DeviceKeyStoreError.keychainFailure(status) }
    }
}

/// Injection seam so the self-revoke test does not touch the real Keychain.
protocol DeviceKeyRotating: AnyObject {
    func rotateForCurrentAccount() throws
}
extension DeviceKeyStore: DeviceKeyRotating {}

import CryptoKit
import Foundation
import Security

enum DeviceKeyStoreError: Error { case keychainFailure(OSStatus) }

/// Keychain-backed storage for the device private key. Follows SharedAuthTokenStore's
/// data-protection pattern, but uses its own service/account and stays out of the
/// app group — the device private key is not shared with Sentinel. The plaintext key
/// only ever lives in the Keychain (system-encrypted) and in memory; it is never uploaded.
final class DeviceKeyStore {
    private let service: String
    private let account: String

    init(service: String = "com.phibrowser.sync.device-key",
         account: String = "device-x25519-v1") {
        self.service = service
        self.account = account
    }

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecUseDataProtectionKeychain as String: true,
         kSecAttrSynchronizable as String: false]
    }

    func loadOrCreatePrivateKey() throws -> Curve25519.KeyAgreement.PrivateKey {
        if let existing = try load() { return existing }
        let key = PhiKeyCrypto.generateDeviceKeyPair()
        do {
            try store(key.rawRepresentation)
            return key
        } catch DeviceKeyStoreError.keychainFailure(errSecDuplicateItem) {
            // Lost a first-registration race: another thread/process already wrote a
            // device key between our load() miss and this store() attempt. Return the
            // winner's key instead of failing, matching loadOrCreatePrivateKey's contract.
            guard let winner = try load() else { throw DeviceKeyStoreError.keychainFailure(errSecDuplicateItem) }
            return winner
        }
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

    private func load() throws -> Curve25519.KeyAgreement.PrivateKey? {
        var query = baseQuery
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

    private func store(_ raw: Data) throws {
        var attrs = baseQuery
        attrs[kSecValueData as String] = raw
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(attrs as CFDictionary, nil)
        guard status == errSecSuccess else { throw DeviceKeyStoreError.keychainFailure(status) }
    }
}

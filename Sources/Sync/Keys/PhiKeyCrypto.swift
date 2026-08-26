import CryptoKit
import Foundation

enum PhiKeyCryptoError: Error { case badVersion, badFormat, decryptFailed }

/// Stateless cryptographic primitives. Zero-knowledge constraint: this type only
/// encrypts/decrypts and never persists any keys.
/// The envelope blob's first byte is the format version (currently 0x01), to allow
/// future evolution.
enum PhiKeyCrypto {
    static let version: UInt8 = 0x01
    // macOS CryptoKit only pairs the Curve25519 KEM with ChaChaPoly (AES-GCM ciphersuites are P256/P384/P521-only).
    private static let ciphersuite = HPKE.Ciphersuite.Curve25519_SHA256_ChachaPoly
    private static let hpkeInfo = Data("phibrowser-sync-hpke-v1".utf8)
    private static let recoveryInfo = Data("phibrowser-sync-recovery-v1".utf8)
    private static let encapLen = 32  // Curve25519 encapsulated key size

    static func generateARK() -> SymmetricKey { SymmetricKey(size: .bits256) }

    static func generateDeviceKeyPair() -> Curve25519.KeyAgreement.PrivateKey {
        Curve25519.KeyAgreement.PrivateKey()
    }

    // Device envelope: [version:1][encapsulatedKey:32][ciphertext]
    static func sealToPublicKey(_ plaintext: Data, recipient: Curve25519.KeyAgreement.PublicKey) throws -> Data {
        var sender = try HPKE.Sender(recipientKey: recipient, ciphersuite: ciphersuite, info: hpkeInfo)
        let ciphertext = try sender.seal(plaintext)
        var out = Data([version])
        out.append(sender.encapsulatedKey)
        out.append(ciphertext)
        return out
    }

    static func openWithPrivateKey(_ envelope: Data, privateKey: Curve25519.KeyAgreement.PrivateKey) throws -> Data {
        guard envelope.count > 1 + encapLen else { throw PhiKeyCryptoError.badFormat }
        guard envelope[envelope.startIndex] == version else { throw PhiKeyCryptoError.badVersion }
        let body = envelope.dropFirst()
        let encap = body.prefix(encapLen)
        let ciphertext = body.dropFirst(encapLen)
        do {
            var recipient = try HPKE.Recipient(privateKey: privateKey, ciphersuite: ciphersuite,
                                               info: hpkeInfo, encapsulatedKey: Data(encap))
            return try recipient.open(Data(ciphertext))
        } catch { throw PhiKeyCryptoError.decryptFailed }
    }

    static func deriveRecoveryKey(entropy: Data, salt: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: entropy),
                               salt: salt, info: recoveryInfo, outputByteCount: 32)
    }

    // Recovery-code envelope: [version:1][AES.GCM.combined](nonce‖ciphertext‖tag)
    static func sealWithSymmetric(_ plaintext: Data, key: SymmetricKey) throws -> Data {
        let box = try AES.GCM.seal(plaintext, using: key)
        guard let combined = box.combined else { throw PhiKeyCryptoError.badFormat }
        return Data([version]) + combined
    }

    static func openWithSymmetric(_ envelope: Data, key: SymmetricKey) throws -> Data {
        guard envelope.count > 1 else { throw PhiKeyCryptoError.badFormat }
        guard envelope[envelope.startIndex] == version else { throw PhiKeyCryptoError.badVersion }
        do {
            let box = try AES.GCM.SealedBox(combined: envelope.dropFirst())
            return try AES.GCM.open(box, using: key)
        } catch { throw PhiKeyCryptoError.decryptFailed }
    }
}

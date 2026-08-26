import CryptoKit
import Foundation
import Security

protocol KeyEnvelopeAPI {
    func putAccount(salt: Data, kdfVersion: String, kdfParams: Data, recoveryEnvelope: Data) async throws -> Bool
    func getAccount() async throws -> AccountKeyStateDTO?
    func postDevice(deviceKeyId: String, publicKey: Data, name: String, platform: String, arkEnvelope: Data?) async throws
    func getDeviceEnvelope(deviceKeyId: String) async throws -> Data?
}
extension KeyEnvelopeAPIClient: KeyEnvelopeAPI {}

enum AccountKeyError: Error { case alreadyInitialized, badRecoveryCode, notInitialized, randomGenerationFailed(OSStatus) }
enum UnlockResult { case unlocked, needsJoin, notSignedIn }

/// Orchestrates the three key-layer flows and caches the decrypted ARK in memory
/// (process lifetime only — it is never persisted to disk).
final class AccountKeyManager {
    private let api: KeyEnvelopeAPI
    private let deviceStore: DeviceKeyStore
    private let kdfVersion = "hkdf-sha256-v1"
    private let platform = "macos"

    private(set) var currentARK: SymmetricKey?
    var deviceStoreForTesting: DeviceKeyStore { deviceStore }

    init(api: KeyEnvelopeAPI, deviceStore: DeviceKeyStore) {
        self.api = api
        self.deviceStore = deviceStore
    }

    func bootstrap() async throws -> String {
        let ark = PhiKeyCrypto.generateARK()
        let (display, entropy) = RecoveryCode.generate()
        var salt = Data(count: 16)
        let saltStatus = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        guard saltStatus == errSecSuccess else { throw AccountKeyError.randomGenerationFailed(saltStatus) }
        let recoveryKey = PhiKeyCrypto.deriveRecoveryKey(entropy: entropy, salt: salt)
        let arkBytes = ark.withUnsafeBytes { Data($0) }
        let recoveryEnvelope = try PhiKeyCrypto.sealWithSymmetric(arkBytes, key: recoveryKey)

        let created = try await api.putAccount(salt: salt, kdfVersion: kdfVersion,
            kdfParams: Data("{}".utf8), recoveryEnvelope: recoveryEnvelope)
        guard created else { throw AccountKeyError.alreadyInitialized }

        try await registerThisDevice(ark: ark)
        currentARK = ark
        return display
    }

    func joinWithRecoveryCode(_ code: String) async throws {
        guard let entropy = RecoveryCode.decode(code) else { throw AccountKeyError.badRecoveryCode }
        guard let account = try await api.getAccount() else { throw AccountKeyError.notInitialized }
        let recoveryKey = PhiKeyCrypto.deriveRecoveryKey(entropy: entropy, salt: account.recoverySalt)
        let arkBytes: Data
        do { arkBytes = try PhiKeyCrypto.openWithSymmetric(account.recoveryArkEnvelope, key: recoveryKey) }
        catch { throw AccountKeyError.badRecoveryCode }  // correctly-formed code that fails to decrypt == wrong code
        let ark = SymmetricKey(data: arkBytes)
        try await registerThisDevice(ark: ark)
        currentARK = ark
    }

    func unlockAtStartup() async throws -> UnlockResult {
        let deviceKeyId = try deviceStore.deviceKeyId()
        guard let envelope = try await api.getDeviceEnvelope(deviceKeyId: deviceKeyId) else {
            // No envelope for this device: whether or not the account is initialized,
            // this device still needs to join.
            return (try await api.getAccount()) == nil ? .needsJoin : .needsJoin
        }
        let priv = try deviceStore.loadOrCreatePrivateKey()
        let arkBytes = try PhiKeyCrypto.openWithPrivateKey(envelope, privateKey: priv)
        currentARK = SymmetricKey(data: arkBytes)
        return .unlocked
    }

    private func registerThisDevice(ark: SymmetricKey) async throws {
        let priv = try deviceStore.loadOrCreatePrivateKey()
        let deviceKeyId = try deviceStore.deviceKeyId()
        let arkBytes = ark.withUnsafeBytes { Data($0) }
        let envelope = try PhiKeyCrypto.sealToPublicKey(arkBytes, recipient: priv.publicKey)
        try await api.postDevice(deviceKeyId: deviceKeyId, publicKey: priv.publicKey.rawRepresentation,
            name: Host.current().localizedName ?? "Mac", platform: platform, arkEnvelope: envelope)
    }
}

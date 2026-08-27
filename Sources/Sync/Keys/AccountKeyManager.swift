import CryptoKit
import Foundation
import Security

protocol KeyEnvelopeAPI {
    func putAccount(salt: Data, kdfVersion: String, kdfParams: Data, recoveryEnvelope: Data) async throws -> Bool
    func getAccount() async throws -> AccountKeyStateDTO?
    func postDevice(deviceKeyId: String, publicKey: Data, name: String, platform: String, arkEnvelope: Data?) async throws
    func getDeviceEnvelope(deviceKeyId: String) async throws -> Data?
    func postJoinRequest(publicKey: Data, name: String, platform: String) async throws -> String
    func listPendingJoinRequests() async throws -> [JoinRequestSummaryDTO]
    func getJoinRequest(id: String) async throws -> JoinRequestDTO
    func approveJoinRequest(id: String, grantedArkEnvelope: Data, resolvedByDeviceKeyId: String) async throws
    func denyJoinRequest(id: String) async throws
    func listProfiles() async throws -> [ProfileSummaryDTO]
    func getProfileKey(uuid: String) async throws -> ProfileKeyDTO?
    func putProfileKey(uuid: String, envelope: Data) async throws -> Bool
}
extension KeyEnvelopeAPIClient: KeyEnvelopeAPI {}

/// Narrow view of `DeviceKeyStore` (just the two operations `AccountKeyManager` needs),
/// injected so tests can supply an in-memory device key without touching the Keychain.
protocol DeviceKeyProviding {
    func loadOrCreatePrivateKey() throws -> Curve25519.KeyAgreement.PrivateKey
    func deviceKeyId() throws -> String
}
extension DeviceKeyStore: DeviceKeyProviding {}

enum AccountKeyError: Error { case alreadyInitialized, badRecoveryCode, notInitialized, randomGenerationFailed(OSStatus) }
enum UnlockResult { case unlocked, needsJoin, notSignedIn }

struct JoinTicket: Equatable { let requestId: String; let verificationCode: String }
enum JoinPollResult: Equatable { case pending(deadline: Date); case approved; case denied; case expired }

/// Orchestrates the three key-layer flows and caches the decrypted ARK in memory
/// (process lifetime only — it is never persisted to disk).
final class AccountKeyManager {
    private let api: KeyEnvelopeAPI
    private let deviceKeyProvider: DeviceKeyProviding
    private let kdfVersion = "hkdf-sha256-v1"
    private let platform = "macos"

    private(set) var currentARK: SymmetricKey?
    var deviceKeyProviderForTesting: DeviceKeyProviding { deviceKeyProvider }

    init(api: KeyEnvelopeAPI, deviceKeyProvider: DeviceKeyProviding) {
        self.api = api
        self.deviceKeyProvider = deviceKeyProvider
    }

    func bootstrap() async throws -> String {
        let ark = PhiKeyCrypto.generateARK()
        let (display, entropy) = try RecoveryCode.generate()
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
        let deviceKeyId = try deviceKeyProvider.deviceKeyId()
        let envelope: Data?
        do {
            envelope = try await api.getDeviceEnvelope(deviceKeyId: deviceKeyId)
        } catch KeyAPIError.http(401, _) {
            // No valid auth token: caller isn't signed in, distinct from a signed-in
            // device that simply hasn't joined yet.
            return .notSignedIn
        }
        guard let envelope else { return .needsJoin }  // no envelope for this device (404) — it needs to join
        let priv = try deviceKeyProvider.loadOrCreatePrivateKey()
        let arkBytes = try PhiKeyCrypto.openWithPrivateKey(envelope, privateKey: priv)
        currentARK = SymmetricKey(data: arkBytes)
        return .unlocked
    }

    /// True if the account has been bootstrapped by some device (recovery envelope exists).
    func accountExists() async throws -> Bool { try await api.getAccount() != nil }

    /// New device asks an already-authorized device to admit it. Returns the request id
    /// plus the verification code the user compares against the approver's screen.
    func requestJoinApproval() async throws -> JoinTicket {
        let priv = try deviceKeyProvider.loadOrCreatePrivateKey()
        let pub = priv.publicKey.rawRepresentation
        let id = try await api.postJoinRequest(publicKey: pub,
            name: Host.current().localizedName ?? "Mac", platform: platform)
        return JoinTicket(requestId: id, verificationCode: PhiKeyCrypto.verificationCode(forPublicKey: pub))
    }

    /// Polls a pending join request. On approval, opens the sealed ARK with this device's
    /// private key, caches it, and registers this device so future startups unlock directly.
    func pollJoin(requestId: String) async throws -> JoinPollResult {
        let dto = try await api.getJoinRequest(id: requestId)
        switch dto.status {
        case "approved":
            let priv = try deviceKeyProvider.loadOrCreatePrivateKey()
            let arkBytes = try PhiKeyCrypto.openWithPrivateKey(dto.grantedArkEnvelope, privateKey: priv)
            let ark = SymmetricKey(data: arkBytes)
            try await registerThisDevice(ark: ark)
            currentARK = ark
            return .approved
        case "denied":  return .denied
        case "expired": return .expired
        default:        return .pending(deadline: dto.createdAt.addingTimeInterval(15 * 60))
        }
    }

    private func registerThisDevice(ark: SymmetricKey) async throws {
        let priv = try deviceKeyProvider.loadOrCreatePrivateKey()
        let deviceKeyId = try deviceKeyProvider.deviceKeyId()
        let arkBytes = ark.withUnsafeBytes { Data($0) }
        let envelope = try PhiKeyCrypto.sealToPublicKey(arkBytes, recipient: priv.publicKey)
        try await api.postDevice(deviceKeyId: deviceKeyId, publicKey: priv.publicKey.rawRepresentation,
            name: Host.current().localizedName ?? "Mac", platform: platform, arkEnvelope: envelope)
    }
}

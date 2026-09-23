import CryptoKit
import Foundation
import Security

protocol KeyEnvelopeAPI {
    func listDevices() async throws -> [AccountDeviceDTO]
    func putAccount(salt: Data, kdfVersion: String, kdfParams: Data, recoveryEnvelope: Data) async throws -> Bool
    func getAccount() async throws -> AccountKeyStateDTO?
    func postDevice(deviceKeyId: String, publicKey: Data, name: String, platform: String, arkEnvelope: Data?) async throws
    func getDeviceEnvelope(deviceKeyId: String) async throws -> Data?
    func revokeDevice(deviceKeyId: String) async throws
    func postJoinRequest(publicKey: Data, name: String, platform: String) async throws -> String
    func listPendingJoinRequests() async throws -> [JoinRequestSummaryDTO]
    func getJoinRequest(id: String) async throws -> JoinRequestDTO
    func approveJoinRequest(id: String, grantedArkEnvelope: Data, resolvedByDeviceKeyId: String) async throws
    func denyJoinRequest(id: String) async throws
    func listProfiles() async throws -> [ProfileSummaryDTO]
    func getProfileKey(uuid: String) async throws -> ProfileKeyDTO?
    func putProfileKey(uuid: String, envelope: Data) async throws -> Bool
    func getDomainKey(domain: String) async throws -> Data?
    func putDomainKey(domain: String, envelope: Data) async throws -> Bool
}
extension KeyEnvelopeAPIClient: KeyEnvelopeAPI {}

/// Narrow view of `DeviceKeyStore` (just the two operations `AccountKeyManager` needs),
/// injected so tests can supply an in-memory device key without touching the Keychain.
protocol DeviceKeyProviding {
    func loadOrCreatePrivateKey() throws -> Curve25519.KeyAgreement.PrivateKey
    func deviceKeyId() throws -> String
    /// Mint a fresh device identity in place (review A10): the server never un-revokes a
    /// fingerprint, so a revoked one must be replaced before this device can register again.
    func rotate() throws
}
extension DeviceKeyStore: DeviceKeyProviding {
    func rotate() throws { try rotateForCurrentAccount() }
}

enum AccountKeyError: Error { case alreadyInitialized, badRecoveryCode, notInitialized, randomGenerationFailed(OSStatus) }
enum UnlockResult { case unlocked, needsJoin, notSignedIn }

/// Review A8. Where `bootstrap()` parks the ARK when the account was created on the server but
/// this device's registration did not go through: the ARK sealed to THIS device's public key —
/// exactly the bytes the server would hold as the device envelope, so nothing leaves the
/// zero-knowledge posture — keyed by the device key id. `unlockAtStartup()` finishes the
/// registration from it. Without this, a failed `POST /keys/v1/devices` after a successful
/// `PUT /keys/v1/account` left an account nobody could open: the ARK and the recovery code
/// only ever lived in `bootstrap()`'s locals, every retry answered 409 `already_initialized`,
/// and the API has no reset.
protocol PendingDeviceRegistrationStoring: AnyObject {
    func load(deviceKeyId: String) -> Data?
    func save(_ envelope: Data, deviceKeyId: String)
    func clear(deviceKeyId: String)
}

/// Default store: `UserDefaults.standard`, one key per device id. The value is ciphertext.
final class DefaultsPendingDeviceRegistrationStore: PendingDeviceRegistrationStoring {
    static let keyPrefix = "phi.sync.pendingDeviceRegistration."
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    private func key(_ deviceKeyId: String) -> String { Self.keyPrefix + deviceKeyId }
    func load(deviceKeyId: String) -> Data? { defaults.data(forKey: key(deviceKeyId)) }
    func save(_ envelope: Data, deviceKeyId: String) { defaults.set(envelope, forKey: key(deviceKeyId)) }
    func clear(deviceKeyId: String) { defaults.removeObject(forKey: key(deviceKeyId)) }
}

struct JoinTicket: Equatable { let requestId: String; let verificationCode: String }
enum JoinPollResult: Equatable { case pending(deadline: Date); case approved; case denied; case expired }

extension Notification.Name {
    /// Posted by an `AccountKeyManager` the moment it caches an ARK it did not have before —
    /// i.e. on every path that unlocks this device: silent startup unlock, first-device
    /// bootstrap, join-by-approval and join-by-recovery-code.
    ///
    /// `object` is the posting `AccountKeyManager`. Observers must re-check the manager they
    /// actually care about rather than trusting the notification alone, and must hop to the
    /// main actor themselves if they need to (the post happens on whichever thread completed
    /// the unlock).
    ///
    /// It exists because the ARK arrives asynchronously and from four different UI flows,
    /// while the things that depend on it (M3-1's settings sync scheduling) are built earlier
    /// and elsewhere. Before this, only the two login-time paths could start the settings
    /// engine, so a device that joined through the Devices pane synced nothing until the next
    /// app launch.
    static let phiAccountKeyDidUnlock = Notification.Name("PhiAccountKeyDidUnlock")
}

/// Orchestrates the three key-layer flows and caches the decrypted ARK in memory
/// (process lifetime only — it is never persisted to disk).
///
/// Isolation: this type is **not** actor-isolated, and it is not main-actor-confined. Its own
/// `async` methods are `nonisolated`, so under SE-0338 they resume on the cooperative pool and
/// assign `currentARK` from there, while `PhiDomainKeyManager`, `SyncKeyController`,
/// `KeyLayerViewModel` and `DevicesSettingViewModel` read it on the main actor. The contract is
/// therefore in the storage, not in the callers: the ARK lives behind `arkLock` and every read
/// and write goes through it, so `currentARK` may be touched from any executor. Nothing else
/// here needs synchronising — `api`, `deviceKeyProvider` and the two constants are immutable
/// after `init`, and the flows themselves are driven from one UI at a time.
///
/// What the lock does *not* give callers is atomicity across statements: a
/// "read, then act on it" sequence still has to tolerate the ARK arriving in between.
final class AccountKeyManager {
    private let api: KeyEnvelopeAPI
    private let deviceKeyProvider: DeviceKeyProviding
    private let kdfVersion = "hkdf-sha256-v1"
    private let platform = "macos"

    /// Guards `arkStorage`. An `NSLock` rather than an actor or `@MainActor`: the four unlock
    /// flows and their callers span the main actor, the cooperative pool and `PhiSyncEngine`'s
    /// own actor, and making the whole type isolated would ripple through every one of them
    /// for a single stored property. `SymmetricKey?` is refcounted, so an unsynchronised
    /// read/write pair is a torn read or an over-release, not merely a stale key.
    private let arkLock = NSLock()
    private var arkStorage: SymmetricKey?

    /// The unlocked ARK. The setter is the single announcement point for "this device is
    /// now unlocked" — cheaper and harder to forget than a call at each of the four flows
    /// that assign it.
    private(set) var currentARK: SymmetricKey? {
        get {
            arkLock.lock()
            defer { arkLock.unlock() }
            return arkStorage
        }
        set {
            arkLock.lock()
            // Only the nil -> unlocked transition is announced. The unlocked ->
            // nil direction has ONE producer, `discardARK()` (self-revoke), and
            // it deliberately announces nothing: every consumer of this manager
            // is dropped in the same teardown, so there is nobody left to notify,
            // and posting an "unlocked" notification here would be a lie.
            // An account switch drops the whole controller (and this manager with
            // it), so no other transition can occur on a live instance.
            let wasLocked = arkStorage == nil
            arkStorage = newValue
            arkLock.unlock()

            guard wasLocked, newValue != nil else { return }
            // Posted outside the lock, deliberately. `NotificationCenter` delivers
            // synchronously on this thread, and an observer's first move is normally to read
            // `currentARK` back — which would deadlock on the non-recursive lock.
            NotificationCenter.default.post(name: .phiAccountKeyDidUnlock, object: self)
        }
    }

    /// Drops the cached ARK for good (self-revoke, §3.3). Not a lock: this device
    /// is leaving the account, and the whole key layer is dropped with it.
    func discardARK() { currentARK = nil }

    /// Explicit local reconfiguration must not retry a parked envelope from the old setup.
    /// Ordinary unlock failures and sign-out keep that recovery state intact.
    func discardLocalRegistration() throws {
        discardARK()
        pendingRegistrations.clear(deviceKeyId: try deviceKeyProvider.deviceKeyId())
    }

    var deviceKeyProviderForTesting: DeviceKeyProviding { deviceKeyProvider }

    private let pendingRegistrations: PendingDeviceRegistrationStoring

    init(api: KeyEnvelopeAPI, deviceKeyProvider: DeviceKeyProviding,
         pendingRegistrations: PendingDeviceRegistrationStoring = DefaultsPendingDeviceRegistrationStore()) {
        self.api = api
        self.deviceKeyProvider = deviceKeyProvider
        self.pendingRegistrations = pendingRegistrations
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

        // From here the account exists on the server and this process holds the only copy of
        // the ARK outside the recovery envelope (review A8). Nothing below may lose it: the
        // ARK is cached first so this device works either way, the recovery code reaches the
        // caller no matter what, and a registration that fails is parked locally and finished
        // by `unlockAtStartup()` — never thrown, which would drop both and leave an account
        // that answers 409 to every retry and has no reset.
        currentARK = ark
        do {
            try await registerThisDevice(ark: ark)
        } catch {
            AppLogError("[phi-sync] account bootstrapped but device registration failed (\(PhiSyncLog.describe(error))); parking it for the next unlock")
            parkRegistration(ark: ark)
        }
        return display
    }

    /// Seal the ARK to this device's own public key and keep it until registration succeeds.
    /// A Keychain failure here is logged and swallowed: the recovery code is still returned,
    /// which is the one thing that must never fail.
    private func parkRegistration(ark: SymmetricKey) {
        do {
            let priv = try deviceKeyProvider.loadOrCreatePrivateKey()
            let deviceKeyId = try deviceKeyProvider.deviceKeyId()
            let envelope = try PhiKeyCrypto.sealToPublicKey(ark.withUnsafeBytes { Data($0) },
                                                            recipient: priv.publicKey)
            pendingRegistrations.save(envelope, deviceKeyId: deviceKeyId)
        } catch {
            AppLogError("[phi-sync] could not park the device registration (\(PhiSyncLog.describe(error))); the recovery code is the only way back in")
        }
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
        guard let envelope else {
            // No envelope for this device (404). Before calling that "needs to join": a bootstrap
            // on this device may have parked its registration (review A8). Finish it from the
            // local copy; if the server still refuses, this session runs on the ARK it holds and
            // the next unlock retries.
            if let parked = pendingRegistrations.load(deviceKeyId: deviceKeyId) {
                let priv = try deviceKeyProvider.loadOrCreatePrivateKey()
                let ark = SymmetricKey(data: try PhiKeyCrypto.openWithPrivateKey(parked, privateKey: priv))
                do {
                    try await registerThisDevice(ark: ark)
                    pendingRegistrations.clear(deviceKeyId: deviceKeyId)
                    AppLogInfo("[phi-sync] finished the parked device registration")
                } catch {
                    AppLogWarn("[phi-sync] parked device registration still failing (\(PhiSyncLog.describe(error))); retrying next unlock")
                }
                currentARK = ark
                return .unlocked
            }
            return .needsJoin
        }
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

    /// Registers this device, and — on the one refusal that can never clear on its own —
    /// re-mints its identity and retries once (review A10). The server answers 409
    /// `device_revoked` to a fingerprint it has revoked, forever; the old code re-posted
    /// the same key on every join attempt and surfaced it as an endless "waiting for
    /// approval" or "invalid recovery code". The ARK is already in hand here (opened with
    /// the old key), so a fresh key can seal it and register.
    private func registerThisDevice(ark: SymmetricKey) async throws {
        do {
            try await postRegistration(ark: ark)
        } catch KeyAPIError.http(409, let body) {
            AppLogWarn("[phi-sync] device registration refused (409 \(body.prefix(64))); rotating the device key and retrying once")
            try deviceKeyProvider.rotate()
            try await postRegistration(ark: ark)
        }
    }

    private func postRegistration(ark: SymmetricKey) async throws {
        let priv = try deviceKeyProvider.loadOrCreatePrivateKey()
        let deviceKeyId = try deviceKeyProvider.deviceKeyId()
        let arkBytes = ark.withUnsafeBytes { Data($0) }
        let envelope = try PhiKeyCrypto.sealToPublicKey(arkBytes, recipient: priv.publicKey)
        try await api.postDevice(deviceKeyId: deviceKeyId, publicKey: priv.publicKey.rawRepresentation,
            name: Host.current().localizedName ?? "Mac", platform: platform, arkEnvelope: envelope)
    }
}

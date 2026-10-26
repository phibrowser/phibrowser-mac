import XCTest
import CryptoKit
@testable import Phi

final class AccountKeyManagerTests: XCTestCase {
    // In-memory fake: one account key state plus a set of per-device envelopes.
    //
    // Every mutable field lives in `State` behind `lock`: the auto-create
    // candidate scan reads Profile envelopes concurrently, off the main actor.
    // The properties keep their names and meaning; hooks are read under the lock
    // and always invoked outside it, since they may touch this fake again.
    final class FakeAPI: KeyEnvelopeAPI {
        private struct State {
            var account: AccountKeyStateDTO?
            var envelopes: [String: Data] = [:]
            var initialized = false
            var deviceEnvelopeError: Error?
            var postDeviceErrorOnce: Error?
            var postDeviceCalls = 0
            var beforeGetDeviceEnvelopeOnce: (() async -> Void)?
            var getDeviceEnvelopeCalls = 0
            var getDeviceEnvelopeInFlight = 0
            var maxGetDeviceEnvelopeInFlight = 0
            var revokedDeviceKeyIds: [String] = []
            var revokeError: Error?
            var resetCalls: [(operationId: UUID, deviceKeyId: String)] = []
            var resetError: Error?
            var beforeResetOnce: (() async -> Void)?
            var joinRequests: [String: JoinRequestDTO] = [:]
            var pendingSummaries: [JoinRequestSummaryDTO] = []
            var postJoinError: Error?
            var lastPostedPublicKey: Data?
            var approveCalls: [(id: String, envelope: Data, resolvedBy: String)] = []
            var denyCalls: [String] = []
            var joinIdCounter = 0
            var profileEnvelopes: [String: Data] = [:]
            var profileEndpointError: Error?
            var profileEndpointErrorOnce: Error?
            var listProfilesError: Error?
            var listProfilesCalls = 0
            var getProfileKeyCalls = 0
            var beforeListProfilesOnce: (() async -> Void)?
            var beforePutProfileKey: (() async -> Void)?
            var domainEnvelopes: [String: Data] = [:]
            var domainEndpointError: Error?
            var getDomainKeyCalls = 0
            var putDomainKeyCalls = 0
            var beforePutDomainKey: ((String) -> Void)?
        }

        private let lock = NSLock()
        private var state = State()

        private func locked<T>(_ body: (inout State) throws -> T) rethrows -> T {
            lock.lock()
            defer { lock.unlock() }
            return try body(&state)
        }

        func listDevices() async throws -> [AccountDeviceDTO] { [] }
        var account: AccountKeyStateDTO? {
            get { locked { $0.account } }
            set { locked { $0.account = newValue } }
        }
        var envelopes: [String: Data] {
            get { locked { $0.envelopes } }
            set { locked { $0.envelopes = newValue } }
        }
        var initialized: Bool {
            get { locked { $0.initialized } }
            set { locked { $0.initialized = newValue } }
        }
        var deviceEnvelopeError: Error? {
            get { locked { $0.deviceEnvelopeError } }
            set { locked { $0.deviceEnvelopeError = newValue } }
        }

        func putAccount(salt: Data, kdfVersion: String, kdfParams: Data, recoveryEnvelope: Data) async throws -> Bool {
            locked { s in
                if s.initialized { return false }
                s.initialized = true
                s.account = AccountKeyStateDTO(recoverySalt: salt, kdfVersion: kdfVersion,
                    kdfParams: kdfParams, recoveryArkEnvelope: recoveryEnvelope, arkGeneration: 1)
                return true
            }
        }
        func getAccount() async throws -> AccountKeyStateDTO? { account }
        /// The next `postDevice` throws this and clears it (review A8 / A10).
        var postDeviceErrorOnce: Error? {
            get { locked { $0.postDeviceErrorOnce } }
            set { locked { $0.postDeviceErrorOnce = newValue } }
        }
        var postDeviceCalls: Int { locked { $0.postDeviceCalls } }
        func postDevice(deviceKeyId: String, publicKey: Data, name: String, platform: String, arkEnvelope: Data?) async throws {
            try locked { s in
                s.postDeviceCalls += 1
                if let error = s.postDeviceErrorOnce { s.postDeviceErrorOnce = nil; throw error }
                if let arkEnvelope { s.envelopes[deviceKeyId] = arkEnvelope }
            }
        }
        /// The next `getDeviceEnvelope` awaits this and clears it, so a test can hold
        /// an unlock parked inside the lookup (BH-52).
        var beforeGetDeviceEnvelopeOnce: (() async -> Void)? {
            get { locked { $0.beforeGetDeviceEnvelopeOnce } }
            set { locked { $0.beforeGetDeviceEnvelopeOnce = newValue } }
        }
        var getDeviceEnvelopeCalls: Int { locked { $0.getDeviceEnvelopeCalls } }
        var getDeviceEnvelopeInFlight: Int { locked { $0.getDeviceEnvelopeInFlight } }
        var maxGetDeviceEnvelopeInFlight: Int { locked { $0.maxGetDeviceEnvelopeInFlight } }
        func getDeviceEnvelope(deviceKeyId: String) async throws -> Data? {
            let hook = locked { s -> (() async -> Void)? in
                s.getDeviceEnvelopeCalls += 1
                s.getDeviceEnvelopeInFlight += 1
                s.maxGetDeviceEnvelopeInFlight = max(s.maxGetDeviceEnvelopeInFlight, s.getDeviceEnvelopeInFlight)
                let hook = s.beforeGetDeviceEnvelopeOnce
                s.beforeGetDeviceEnvelopeOnce = nil
                return hook
            }
            defer { locked { $0.getDeviceEnvelopeInFlight -= 1 } }
            if let hook { await hook() }
            return try locked { s in
                if let error = s.deviceEnvelopeError { throw error }
                return s.envelopes[deviceKeyId]
            }
        }

        var revokedDeviceKeyIds: [String] { locked { $0.revokedDeviceKeyIds } }
        var revokeError: Error? {
            get { locked { $0.revokeError } }
            set { locked { $0.revokeError = newValue } }
        }
        func revokeDevice(deviceKeyId: String) async throws {
            try locked { s in
                if let error = s.revokeError { throw error }
                s.revokedDeviceKeyIds.append(deviceKeyId)
            }
        }

        /// Every reset request is recorded, refused or not, so a test can assert the
        /// operation UUID a retry reused.
        var resetCalls: [(operationId: UUID, deviceKeyId: String)] { locked { $0.resetCalls } }
        var resetError: Error? {
            get { locked { $0.resetError } }
            set { locked { $0.resetError = newValue } }
        }
        /// Runs once inside the next reset request, before it is recorded, so a test can
        /// hold the request in flight.
        var beforeResetOnce: (() async -> Void)? {
            get { locked { $0.beforeResetOnce } }
            set { locked { $0.beforeResetOnce = newValue } }
        }
        func resetAccount(operationId: UUID, deviceKeyId: String) async throws {
            let hook = locked { s -> (() async -> Void)? in
                let hook = s.beforeResetOnce
                s.beforeResetOnce = nil
                return hook
            }
            if let hook { await hook() }
            try locked { s in
                s.resetCalls.append((operationId, deviceKeyId))
                if let error = s.resetError { throw error }
            }
        }

        // join queue
        var joinRequests: [String: JoinRequestDTO] {
            get { locked { $0.joinRequests } }
            set { locked { $0.joinRequests = newValue } }
        }
        var pendingSummaries: [JoinRequestSummaryDTO] {
            get { locked { $0.pendingSummaries } }
            set { locked { $0.pendingSummaries = newValue } }
        }
        var postJoinError: Error? {
            get { locked { $0.postJoinError } }
            set { locked { $0.postJoinError = newValue } }
        }
        var lastPostedPublicKey: Data? {
            get { locked { $0.lastPostedPublicKey } }
            set { locked { $0.lastPostedPublicKey = newValue } }
        }
        var approveCalls: [(id: String, envelope: Data, resolvedBy: String)] {
            get { locked { $0.approveCalls } }
            set { locked { $0.approveCalls = newValue } }
        }
        var denyCalls: [String] {
            get { locked { $0.denyCalls } }
            set { locked { $0.denyCalls = newValue } }
        }
        static let fixedCreatedAt = Date(timeIntervalSince1970: 1_700_000_000)

        func postJoinRequest(publicKey: Data, name: String, platform: String) async throws -> String {
            try locked { s in
                if let error = s.postJoinError { throw error }
                s.lastPostedPublicKey = publicKey
                s.joinIdCounter += 1
                let id = "join-\(s.joinIdCounter)"
                s.joinRequests[id] = JoinRequestDTO(requestId: id, requestingPublicKey: publicKey, name: name,
                    platform: platform, status: "pending", grantedArkEnvelope: Data(),
                    createdAt: Self.fixedCreatedAt, resolvedByDeviceKeyId: nil)
                return id
            }
        }
        func listPendingJoinRequests() async throws -> [JoinRequestSummaryDTO] { pendingSummaries }
        func getJoinRequest(id: String) async throws -> JoinRequestDTO {
            guard let dto = joinRequests[id] else { throw JoinRequestError.notFound }
            return dto
        }
        func approveJoinRequest(id: String, grantedArkEnvelope: Data, resolvedByDeviceKeyId: String) async throws {
            locked { s in
                s.approveCalls.append((id, grantedArkEnvelope, resolvedByDeviceKeyId))
                if let dto = s.joinRequests[id] {
                    s.joinRequests[id] = JoinRequestDTO(requestId: dto.requestId, requestingPublicKey: dto.requestingPublicKey,
                        name: dto.name, platform: dto.platform, status: "approved", grantedArkEnvelope: grantedArkEnvelope,
                        createdAt: dto.createdAt, resolvedByDeviceKeyId: resolvedByDeviceKeyId)
                }
            }
        }
        func denyJoinRequest(id: String) async throws { locked { $0.denyCalls.append(id) } }

        // profile keys
        var profileEnvelopes: [String: Data] {
            get { locked { $0.profileEnvelopes } }
            set { locked { $0.profileEnvelopes = newValue } }
        }
        static let profileCreatedAt = Date(timeIntervalSince1970: 1_700_000_000)

        /// Error injection for the per-profile endpoints. Kept separate from
        /// `listProfilesError` so a test can make a single profile lookup fail
        /// transiently while the account-wide listing still succeeds (and vice
        /// versa) — the two failures take different paths through
        /// `SyncKeyController.resolveMappings()`.
        var profileEndpointError: Error? {
            get { locked { $0.profileEndpointError } }
            set { locked { $0.profileEndpointError = newValue } }
        }
        /// Applies only to the next per-profile call, then clears. Persistent profileEndpointError
        /// cannot model failure followed by recovery, which applyPairingDecisions needs when
        /// reloading candidates after failure.
        var profileEndpointErrorOnce: Error? {
            get { locked { $0.profileEndpointErrorOnce } }
            set { locked { $0.profileEndpointErrorOnce = newValue } }
        }
        var listProfilesError: Error? {
            get { locked { $0.listProfilesError } }
            set { locked { $0.listProfilesError = newValue } }
        }
        var listProfilesCalls: Int { locked { $0.listProfilesCalls } }
        var getProfileKeyCalls: Int { locked { $0.getProfileKeyCalls } }

        /// Fired once at the top of the next `listProfiles`, then cleared: a mapping pass is
        /// suspended there after it resolved its locals, so a test can interleave with it.
        var beforeListProfilesOnce: (() async -> Void)? {
            get { locked { $0.beforeListProfilesOnce } }
            set { locked { $0.beforeListProfilesOnce = newValue } }
        }
        func listProfiles() async throws -> [ProfileSummaryDTO] {
            let hook = locked { s -> (() async -> Void)? in
                let hook = s.beforeListProfilesOnce
                s.beforeListProfilesOnce = nil
                return hook
            }
            if let hook { await hook() }
            return try locked { s in
                s.listProfilesCalls += 1
                if let error = s.listProfilesError { throw error }
                return s.profileEnvelopes.keys.sorted().map {
                    ProfileSummaryDTO(profileUuid: $0, hasEnvelope: true, createdAt: Self.profileCreatedAt)
                }
            }
        }
        func getProfileKey(uuid: String) async throws -> ProfileKeyDTO? {
            try locked { s in
                s.getProfileKeyCalls += 1
                if let error = s.profileEndpointErrorOnce { s.profileEndpointErrorOnce = nil; throw error }
                if let error = s.profileEndpointError { throw error }
                guard let e = s.profileEnvelopes[uuid] else { return nil }
                return ProfileKeyDTO(profileUuid: uuid, profileKeyEnvelope: e, createdAt: Self.profileCreatedAt)
            }
        }
        /// Fired at the top of `putProfileKey`, before the store is touched: a
        /// test can suspend here so a second `resolveMappings()` pass gets to
        /// interleave inside the first one's registration.
        var beforePutProfileKey: (() async -> Void)? {
            get { locked { $0.beforePutProfileKey } }
            set { locked { $0.beforePutProfileKey = newValue } }
        }
        func replaceProfileKeyEnvelope(uuid: String, expected: Data, envelope: Data) async throws -> Bool {
            locked { s in
                guard s.profileEnvelopes[uuid] == expected else { return false }
                s.profileEnvelopes[uuid] = envelope
                return true
            }
        }
        func putProfileKey(uuid: String, envelope: Data) async throws -> Bool {
            if let hook = beforePutProfileKey { await hook() }
            return try locked { s in
                if let error = s.profileEndpointErrorOnce { s.profileEndpointErrorOnce = nil; throw error }
                if let error = s.profileEndpointError { throw error }
                if s.profileEnvelopes[uuid] != nil { return false }
                s.profileEnvelopes[uuid] = envelope
                return true
            }
        }

        // domain keys (account-level, one per domain — e.g. "phi")
        var domainEnvelopes: [String: Data] {
            get { locked { $0.domainEnvelopes } }
            set { locked { $0.domainEnvelopes = newValue } }
        }
        var domainEndpointError: Error? {
            get { locked { $0.domainEndpointError } }
            set { locked { $0.domainEndpointError = newValue } }
        }
        var getDomainKeyCalls: Int { locked { $0.getDomainKeyCalls } }
        var putDomainKeyCalls: Int { locked { $0.putDomainKeyCalls } }
        /// Hook fired at the top of `putDomainKey`, so a test can simulate another
        /// device winning the first-use race between this device's GET and PUT.
        var beforePutDomainKey: ((String) -> Void)? {
            get { locked { $0.beforePutDomainKey } }
            set { locked { $0.beforePutDomainKey = newValue } }
        }

        func getDomainKey(domain: String) async throws -> Data? {
            try locked { s in
                s.getDomainKeyCalls += 1
                if let error = s.domainEndpointError { throw error }
                return s.domainEnvelopes[domain]
            }
        }
        func putDomainKey(domain: String, envelope: Data) async throws -> Bool {
            let hook = locked { s -> ((String) -> Void)? in
                s.putDomainKeyCalls += 1
                return s.beforePutDomainKey
            }
            hook?(domain)
            return try locked { s in
                if let error = s.domainEndpointError { throw error }
                if s.domainEnvelopes[domain] != nil { return false }  // 409: first writer wins
                s.domainEnvelopes[domain] = envelope
                return true
            }
        }
    }

    // In-memory fake device key: same fingerprinting algorithm as `DeviceKeyStore`
    // (SHA-256 of the public key, first 16 bytes, base64url), but backed by a
    // process-local key instead of the Keychain — keeps this suite independent of
    // the Data Protection Keychain entitlement.
    /// In-memory `PendingDeviceRegistrationStoring` (review A8), shared between two managers to
    /// model a relaunch.
    final class MemoryPendingRegistrations: PendingDeviceRegistrationStoring {
        private(set) var envelopes: [String: Data] = [:]
        func load(deviceKeyId: String) -> Data? { envelopes[deviceKeyId] }
        func save(_ envelope: Data, deviceKeyId: String) { envelopes[deviceKeyId] = envelope }
        func clear(deviceKeyId: String) { envelopes.removeValue(forKey: deviceKeyId) }
    }

    final class FakeDeviceKeyProvider: DeviceKeyProviding {
        private var privateKey = Curve25519.KeyAgreement.PrivateKey()
        private(set) var rotations = 0

        func loadOrCreatePrivateKey() throws -> Curve25519.KeyAgreement.PrivateKey { privateKey }

        /// Mint a fresh identity, as `DeviceKeyStore.rotateForCurrentAccount()` does (review A10).
        func rotate() throws {
            privateKey = Curve25519.KeyAgreement.PrivateKey()
            rotations += 1
        }

        func deviceKeyId() throws -> String {
            let digest = SHA256.hash(data: privateKey.publicKey.rawRepresentation)
            let prefix = Data(digest.prefix(16))
            return prefix.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
    }

    private func makeManager(_ api: FakeAPI) -> AccountKeyManager {
        AccountKeyManager(api: api, deviceKeyProvider: FakeDeviceKeyProvider())
    }

    func testBootstrapThenStartupUnlocks() async throws {
        let api = FakeAPI()
        let mgr = makeManager(api)
        let code = try await mgr.bootstrap()
        XCTAssertFalse(code.isEmpty)
        XCTAssertNotNil(mgr.currentARK)

        // New process, same device (same provider): startup should unwrap the same ARK
        // from the device envelope.
        let fresh = AccountKeyManager(api: api, deviceKeyProvider: mgr.deviceKeyProviderForTesting)
        let result = try await fresh.unlockAtStartup()
        XCTAssertEqual(result, .unlocked)
        XCTAssertEqual(fresh.currentARK!.withUnsafeBytes { Data($0) },
                       mgr.currentARK!.withUnsafeBytes { Data($0) })
    }

    /// Review A8: `PUT /keys/v1/account` succeeded, `POST /keys/v1/devices` did not. The old
    /// code threw, dropping the ARK and the recovery code with the account already initialized
    /// on the server — every retry 409, no reset, an account nobody could ever open. The
    /// recovery code must reach the caller, this device must keep working, and the
    /// registration is finished from the parked local copy on the next unlock.
    func testBootstrapSurvivesAFailedDeviceRegistrationAndFinishesItOnTheNextUnlock() async throws {
        let api = FakeAPI()
        let provider = FakeDeviceKeyProvider()
        let pending = MemoryPendingRegistrations()
        api.postDeviceErrorOnce = KeyAPIError.transport(URLError(.notConnectedToInternet))
        let mgr = AccountKeyManager(api: api, deviceKeyProvider: provider, pendingRegistrations: pending)

        let code = try await mgr.bootstrap()

        XCTAssertFalse(code.isEmpty, "the recovery code is the one thing that must never be lost")
        XCTAssertNotNil(mgr.currentARK, "this device keeps working on the ARK it minted")
        XCTAssertTrue(api.envelopes.isEmpty, "precondition: the server never received the device envelope")
        XCTAssertNotNil(pending.load(deviceKeyId: try provider.deviceKeyId()), "the registration is parked locally")

        // Relaunch: no envelope on the server, but the parked one finishes the registration.
        let fresh = AccountKeyManager(api: api, deviceKeyProvider: provider, pendingRegistrations: pending)
        let result = try await fresh.unlockAtStartup()
        XCTAssertEqual(result, .unlocked)
        XCTAssertEqual(api.envelopes.count, 1)
        XCTAssertNil(pending.load(deviceKeyId: try provider.deviceKeyId()))
        XCTAssertEqual(fresh.currentARK!.withUnsafeBytes { Data($0) },
                       mgr.currentARK!.withUnsafeBytes { Data($0) })

        // And the recovery code the user was shown still admits another device.
        let second = makeManager(api)
        try await second.joinWithRecoveryCode(code)
        XCTAssertEqual(second.currentARK!.withUnsafeBytes { Data($0) },
                       mgr.currentARK!.withUnsafeBytes { Data($0) })
    }

    func testExplicitResetDiscardsParkedRegistrationButOrdinaryDiscardKeepsIt() async throws {
        let api = FakeAPI()
        let provider = FakeDeviceKeyProvider()
        let pending = MemoryPendingRegistrations()
        api.postDeviceErrorOnce = KeyAPIError.transport(URLError(.notConnectedToInternet))
        let manager = AccountKeyManager(api: api, deviceKeyProvider: provider, pendingRegistrations: pending)
        _ = try await manager.bootstrap()
        let deviceID = try provider.deviceKeyId()
        manager.discardARK()
        XCTAssertNotNil(pending.load(deviceKeyId: deviceID))
        try manager.discardLocalRegistration()
        XCTAssertNil(pending.load(deviceKeyId: deviceID))
        let fresh = AccountKeyManager(api: api, deviceKeyProvider: provider, pendingRegistrations: pending)
        let state = try await fresh.unlockAtStartup()
        XCTAssertEqual(state, .needsJoin)
        XCTAssertTrue(api.envelopes.isEmpty)
    }

    /// Review A10: the server refuses a revoked device fingerprint forever (409
    /// `device_revoked`). Re-registering the same key would loop; the manager mints a new
    /// identity and retries once, so a Mac whose key was revoked can rejoin.
    func testARevokedDeviceIdentityIsRotatedAndTheJoinRetried() async throws {
        let api = FakeAPI()
        let code = try await makeManager(api).bootstrap()

        let provider = FakeDeviceKeyProvider()
        let revokedId = try provider.deviceKeyId()
        api.postDeviceErrorOnce = KeyAPIError.http(409, #"{"error":"device_revoked"}"#)
        let joiner = AccountKeyManager(api: api, deviceKeyProvider: provider)

        try await joiner.joinWithRecoveryCode(code)

        XCTAssertEqual(provider.rotations, 1)
        let newId = try provider.deviceKeyId()
        XCTAssertNotEqual(newId, revokedId)
        XCTAssertNotNil(api.envelopes[newId], "the retry registered the fresh identity")
        XCTAssertNil(api.envelopes[revokedId])
        XCTAssertEqual(api.postDeviceCalls, 3, "bootstrap, the refused attempt, the retry")
        XCTAssertNotNil(joiner.currentARK)
    }

    func testSecondDeviceJoinsWithRecoveryCode() async throws {
        let api = FakeAPI()
        let first = makeManager(api)
        let code = try await first.bootstrap()
        let firstARK = first.currentARK!.withUnsafeBytes { Data($0) }

        // Second device (different provider) joins with the recovery code and gets the same ARK.
        let second = makeManager(api)
        try await second.joinWithRecoveryCode(code)
        XCTAssertEqual(second.currentARK!.withUnsafeBytes { Data($0) }, firstARK)

        // The second device now unlocks normally on subsequent startup.
        let secondStartup = try await second.unlockAtStartup()
        XCTAssertEqual(secondStartup, .unlocked)
    }

    func testBadRecoveryCodeRejected() async throws {
        let api = FakeAPI()
        _ = try await makeManager(api).bootstrap()
        let joiner = makeManager(api)
        do { try await joiner.joinWithRecoveryCode("00000-00000-00000-00000-00000-00"); XCTFail() }
        catch AccountKeyError.badRecoveryCode {} // ok
    }

    func testStartupOnFreshDeviceNeedsJoin() async throws {
        let api = FakeAPI()
        _ = try await makeManager(api).bootstrap()   // account initialized, but this new device has no envelope
        let fresh = makeManager(api)
        let freshStartup = try await fresh.unlockAtStartup()
        XCTAssertEqual(freshStartup, .needsJoin)
    }

    func testStartupNotSignedInOn401() async throws {
        let api = FakeAPI()
        api.deviceEnvelopeError = KeyAPIError.http(401, "")
        let mgr = makeManager(api)
        let result = try await mgr.unlockAtStartup()
        XCTAssertEqual(result, .notSignedIn)
    }

    func testRecoveryCodeValidFormatButWrongKeyRejected() async throws {
        let api = FakeAPI()
        _ = try await makeManager(api).bootstrap()

        // A syntactically and checksum-valid recovery code that was never associated
        // with this account's salt/envelope: RecoveryCode.decode() succeeds, but the
        // derived key must fail to open the account's AES-GCM envelope.
        let (unrelatedCode, _) = try RecoveryCode.generate()
        let joiner = makeManager(api)
        do {
            try await joiner.joinWithRecoveryCode(unrelatedCode)
            XCTFail("expected badRecoveryCode")
        } catch AccountKeyError.badRecoveryCode {} // ok: reached via the openWithSymmetric catch, not the decode guard
    }

    func testSecondBootstrapOnSameAccountRejected() async throws {
        let api = FakeAPI()
        let mgr = makeManager(api)
        _ = try await mgr.bootstrap()
        do {
            _ = try await mgr.bootstrap()
            XCTFail("expected alreadyInitialized")
        } catch AccountKeyError.alreadyInitialized {} // ok: FakeAPI.putAccount returns false on the second call
    }

    func testJoinOnNeverBootstrappedAccountRejected() async throws {
        let api = FakeAPI() // never bootstrapped: getAccount() returns nil
        let (code, _) = try RecoveryCode.generate()
        let joiner = makeManager(api)
        do {
            try await joiner.joinWithRecoveryCode(code)
            XCTFail("expected notInitialized")
        } catch AccountKeyError.notInitialized {} // ok: FakeAPI.getAccount() returns nil
    }

    func testRequestJoinApprovalPostsAndReturnsMatchingCode() async throws {
        let api = FakeAPI()
        let provider = FakeDeviceKeyProvider()
        let mgr = AccountKeyManager(api: api, deviceKeyProvider: provider)
        let ticket = try await mgr.requestJoinApproval()
        XCTAssertFalse(ticket.requestId.isEmpty)
        let pub = try provider.loadOrCreatePrivateKey().publicKey.rawRepresentation
        XCTAssertEqual(ticket.verificationCode, PhiKeyCrypto.verificationCode(forPublicKey: pub))
        XCTAssertEqual(api.lastPostedPublicKey, pub)
    }

    func testPollJoinPendingReturnsDeadline() async throws {
        let api = FakeAPI()
        let mgr = AccountKeyManager(api: api, deviceKeyProvider: FakeDeviceKeyProvider())
        let ticket = try await mgr.requestJoinApproval()
        let result = try await mgr.pollJoin(requestId: ticket.requestId)
        XCTAssertEqual(result, .pending(deadline: FakeAPI.fixedCreatedAt.addingTimeInterval(900)))
    }

    func testPollJoinApprovedUnlocksAndRegisters() async throws {
        // Approver bootstraps to obtain an ARK.
        let api = FakeAPI()
        let approver = AccountKeyManager(api: api, deviceKeyProvider: FakeDeviceKeyProvider())
        _ = try await approver.bootstrap()
        let arkBytes = approver.currentARK!.withUnsafeBytes { Data($0) }

        // Joiner requests, then we simulate the approver sealing the ARK to the joiner's key.
        let joinerProvider = FakeDeviceKeyProvider()
        let joiner = AccountKeyManager(api: api, deviceKeyProvider: joinerProvider)
        let ticket = try await joiner.requestJoinApproval()
        let joinerPub = try joinerProvider.loadOrCreatePrivateKey().publicKey
        let sealed = try PhiKeyCrypto.sealToPublicKey(arkBytes, recipient: joinerPub)
        try await api.approveJoinRequest(id: ticket.requestId, grantedArkEnvelope: sealed, resolvedByDeviceKeyId: "approver")

        let result = try await joiner.pollJoin(requestId: ticket.requestId)
        XCTAssertEqual(result, .approved)
        XCTAssertEqual(joiner.currentARK!.withUnsafeBytes { Data($0) }, arkBytes)
        // registerThisDevice ran: this device's envelope is now stored.
        let joinerId = try joinerProvider.deviceKeyId()
        XCTAssertNotNil(api.envelopes[joinerId])
    }

    func testPollJoinDeniedAndExpired() async throws {
        let api = FakeAPI()
        let mgr = AccountKeyManager(api: api, deviceKeyProvider: FakeDeviceKeyProvider())
        let t1 = try await mgr.requestJoinApproval()
        api.joinRequests[t1.requestId] = JoinRequestDTO(requestId: t1.requestId, requestingPublicKey: Data(),
            name: "", platform: "macos", status: "denied", grantedArkEnvelope: Data(),
            createdAt: FakeAPI.fixedCreatedAt, resolvedByDeviceKeyId: nil)
        let r1 = try await mgr.pollJoin(requestId: t1.requestId)
        XCTAssertEqual(r1, .denied)

        api.joinRequests[t1.requestId] = JoinRequestDTO(requestId: t1.requestId, requestingPublicKey: Data(),
            name: "", platform: "macos", status: "expired", grantedArkEnvelope: Data(),
            createdAt: FakeAPI.fixedCreatedAt, resolvedByDeviceKeyId: nil)
        let r2 = try await mgr.pollJoin(requestId: t1.requestId)
        XCTAssertEqual(r2, .expired)
    }

    func testAccountExists() async throws {
        let api = FakeAPI()
        let mgr = AccountKeyManager(api: api, deviceKeyProvider: FakeDeviceKeyProvider())
        let before = try await mgr.accountExists()
        XCTAssertFalse(before)
        _ = try await mgr.bootstrap()
        let after = try await mgr.accountExists()
        XCTAssertTrue(after)
    }

    // MARK: - Unlock announcement

    /// The ARK arrives from four flows, three of which live in the Devices pane and never call
    /// back into `PhiChromiumCoordinator` — which is why M3-1's settings engine was built on a
    /// freshly joined device and then never scheduled a round. `.phiAccountKeyDidUnlock` is the
    /// one announcement every flow makes, so it has to fire for each of them. (`bootstrap` is
    /// covered by `testUnlockIsAnnouncedOnce`.)
    func testJoinWithRecoveryCodeAnnouncesTheUnlock() async throws {
        let api = FakeAPI()
        let code = try await makeManager(api).bootstrap()
        let joiner = makeManager(api)
        let expectation = XCTNSNotificationExpectation(name: .phiAccountKeyDidUnlock, object: joiner)

        try await joiner.joinWithRecoveryCode(code)

        await fulfillment(of: [expectation], timeout: 1)
    }

    func testStartupUnlockAnnouncesTheUnlock() async throws {
        let api = FakeAPI()
        let first = makeManager(api)
        _ = try await first.bootstrap()
        let fresh = AccountKeyManager(api: api, deviceKeyProvider: first.deviceKeyProviderForTesting)
        let expectation = XCTNSNotificationExpectation(name: .phiAccountKeyDidUnlock, object: fresh)

        _ = try await fresh.unlockAtStartup()

        await fulfillment(of: [expectation], timeout: 1)
    }

    func testApprovedJoinAnnouncesTheUnlock() async throws {
        let api = FakeAPI()
        let approver = makeManager(api)
        _ = try await approver.bootstrap()
        let joinerProvider = FakeDeviceKeyProvider()
        let joiner = AccountKeyManager(api: api, deviceKeyProvider: joinerProvider)
        let ticket = try await joiner.requestJoinApproval()
        let sealed = try PhiKeyCrypto.sealToPublicKey(
            approver.currentARK!.withUnsafeBytes { Data($0) },
            recipient: joinerProvider.loadOrCreatePrivateKey().publicKey)
        try await api.approveJoinRequest(id: ticket.requestId, grantedArkEnvelope: sealed,
                                         resolvedByDeviceKeyId: "approver")
        let expectation = XCTNSNotificationExpectation(name: .phiAccountKeyDidUnlock, object: joiner)

        let result = try await joiner.pollJoin(requestId: ticket.requestId)
        XCTAssertEqual(result, .approved)

        await fulfillment(of: [expectation], timeout: 1)
    }

    /// Only the nil -> unlocked edge announces: a second unlock of an already-unlocked manager
    /// must not restart anything downstream.
    func testUnlockIsAnnouncedOnce() async throws {
        let api = FakeAPI()
        let mgr = makeManager(api)
        let once = XCTNSNotificationExpectation(name: .phiAccountKeyDidUnlock, object: mgr)
        once.expectedFulfillmentCount = 1
        once.assertForOverFulfill = true

        _ = try await mgr.bootstrap()
        _ = try await mgr.unlockAtStartup()

        await fulfillment(of: [once], timeout: 1)
    }

    // MARK: - ARK storage

    /// Hands a non-`Sendable` value to another thread deliberately. `AccountKeyManager` is not
    /// `Sendable` and is not meant to become so — only its ARK store is synchronised — so the
    /// test below has to opt out of the compiler's check to exercise exactly that.
    private final class UnsafeHandoff<T>: @unchecked Sendable {
        let value: T
        init(_ value: T) { self.value = value }
    }

    /// The ARK store is lock-protected, which is what lets `AccountKeyManager` stay
    /// un-isolated: its own `async` methods assign `currentARK` from the cooperative pool
    /// (SE-0338) while `PhiDomainKeyManager` and the key-layer view models read it on the main
    /// actor. This runs both sides against each other — the reads are off the cooperative pool
    /// on purpose, so the unlock really is concurrent with them rather than interleaved by the
    /// same executor. A reader may legitimately see either `nil` or the unlocked key; what it
    /// must never see is a half-assigned one, which is what a thread-sanitizer run of this test
    /// would catch if the storage regressed to a plain `var`.
    func testTheARKStoreToleratesReadsConcurrentWithTheUnlockWrite() async throws {
        let api = FakeAPI()
        let first = makeManager(api)
        _ = try await first.bootstrap()
        let expected = first.currentARK!.withUnsafeBytes { Data($0) }
        let fresh = AccountKeyManager(api: api, deviceKeyProvider: first.deviceKeyProviderForTesting)

        let readersDone = expectation(description: "concurrent readers finished")
        let handoff = UnsafeHandoff(fresh)
        DispatchQueue.global(qos: .userInitiated).async {
            for _ in 0..<20_000 {
                guard let ark = handoff.value.currentARK else { continue }
                XCTAssertEqual(ark.withUnsafeBytes { Data($0) }, expected)
            }
            readersDone.fulfill()
        }

        let result = try await fresh.unlockAtStartup()

        await fulfillment(of: [readersDone], timeout: 10)
        XCTAssertEqual(result, .unlocked)
        XCTAssertEqual(fresh.currentARK!.withUnsafeBytes { Data($0) }, expected)
    }
}

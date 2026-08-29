import XCTest
import CryptoKit
@testable import Phi

final class AccountKeyManagerTests: XCTestCase {
    // In-memory fake: one account key state plus a set of per-device envelopes.
    final class FakeAPI: KeyEnvelopeAPI {
        var account: AccountKeyStateDTO?
        var envelopes: [String: Data] = [:]
        var initialized = false
        var deviceEnvelopeError: Error?

        func putAccount(salt: Data, kdfVersion: String, kdfParams: Data, recoveryEnvelope: Data) async throws -> Bool {
            if initialized { return false }
            initialized = true
            account = AccountKeyStateDTO(recoverySalt: salt, kdfVersion: kdfVersion,
                kdfParams: kdfParams, recoveryArkEnvelope: recoveryEnvelope, arkGeneration: 1)
            return true
        }
        func getAccount() async throws -> AccountKeyStateDTO? { account }
        func postDevice(deviceKeyId: String, publicKey: Data, name: String, platform: String, arkEnvelope: Data?) async throws {
            if let arkEnvelope { envelopes[deviceKeyId] = arkEnvelope }
        }
        func getDeviceEnvelope(deviceKeyId: String) async throws -> Data? {
            if let deviceEnvelopeError { throw deviceEnvelopeError }
            return envelopes[deviceKeyId]
        }

        // join queue
        var joinRequests: [String: JoinRequestDTO] = [:]
        var pendingSummaries: [JoinRequestSummaryDTO] = []
        var postJoinError: Error?
        var lastPostedPublicKey: Data?
        var approveCalls: [(id: String, envelope: Data, resolvedBy: String)] = []
        var denyCalls: [String] = []
        private var joinIdCounter = 0
        static let fixedCreatedAt = Date(timeIntervalSince1970: 1_700_000_000)

        func postJoinRequest(publicKey: Data, name: String, platform: String) async throws -> String {
            if let postJoinError { throw postJoinError }
            lastPostedPublicKey = publicKey
            joinIdCounter += 1
            let id = "join-\(joinIdCounter)"
            joinRequests[id] = JoinRequestDTO(requestId: id, requestingPublicKey: publicKey, name: name,
                platform: platform, status: "pending", grantedArkEnvelope: Data(),
                createdAt: Self.fixedCreatedAt, resolvedByDeviceKeyId: nil)
            return id
        }
        func listPendingJoinRequests() async throws -> [JoinRequestSummaryDTO] { pendingSummaries }
        func getJoinRequest(id: String) async throws -> JoinRequestDTO {
            guard let dto = joinRequests[id] else { throw JoinRequestError.notFound }
            return dto
        }
        func approveJoinRequest(id: String, grantedArkEnvelope: Data, resolvedByDeviceKeyId: String) async throws {
            approveCalls.append((id, grantedArkEnvelope, resolvedByDeviceKeyId))
            if let dto = joinRequests[id] {
                joinRequests[id] = JoinRequestDTO(requestId: dto.requestId, requestingPublicKey: dto.requestingPublicKey,
                    name: dto.name, platform: dto.platform, status: "approved", grantedArkEnvelope: grantedArkEnvelope,
                    createdAt: dto.createdAt, resolvedByDeviceKeyId: resolvedByDeviceKeyId)
            }
        }
        func denyJoinRequest(id: String) async throws { denyCalls.append(id) }

        // profile keys
        var profileEnvelopes: [String: Data] = [:]
        static let profileCreatedAt = Date(timeIntervalSince1970: 1_700_000_000)

        /// Error injection for the per-profile endpoints. Kept separate from
        /// `listProfilesError` so a test can make a single profile lookup fail
        /// transiently while the account-wide listing still succeeds (and vice
        /// versa) — the two failures take different paths through
        /// `SyncKeyController.resolveMappings()`.
        var profileEndpointError: Error?
        var listProfilesError: Error?

        func listProfiles() async throws -> [ProfileSummaryDTO] {
            if let listProfilesError { throw listProfilesError }
            return profileEnvelopes.keys.sorted().map {
                ProfileSummaryDTO(profileUuid: $0, hasEnvelope: true, createdAt: Self.profileCreatedAt)
            }
        }
        func getProfileKey(uuid: String) async throws -> ProfileKeyDTO? {
            if let profileEndpointError { throw profileEndpointError }
            guard let e = profileEnvelopes[uuid] else { return nil }
            return ProfileKeyDTO(profileUuid: uuid, profileKeyEnvelope: e, createdAt: Self.profileCreatedAt)
        }
        func putProfileKey(uuid: String, envelope: Data) async throws -> Bool {
            if let profileEndpointError { throw profileEndpointError }
            if profileEnvelopes[uuid] != nil { return false }
            profileEnvelopes[uuid] = envelope
            return true
        }
    }

    // In-memory fake device key: same fingerprinting algorithm as `DeviceKeyStore`
    // (SHA-256 of the public key, first 16 bytes, base64url), but backed by a
    // process-local key instead of the Keychain — keeps this suite independent of
    // the Data Protection Keychain entitlement.
    final class FakeDeviceKeyProvider: DeviceKeyProviding {
        private let privateKey = Curve25519.KeyAgreement.PrivateKey()

        func loadOrCreatePrivateKey() throws -> Curve25519.KeyAgreement.PrivateKey { privateKey }

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
}

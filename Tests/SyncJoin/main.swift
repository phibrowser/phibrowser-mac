import CryptoKit
import Foundation

// Real crypto, account manager and verification state machine; no Keychain, app host or network.
final class DeviceKeyStore {
    var key = Curve25519.KeyAgreement.PrivateKey()
    func loadOrCreatePrivateKey() throws -> Curve25519.KeyAgreement.PrivateKey { key }
    func deviceKeyId() throws -> String { "test-device" }
    func rotateForCurrentAccount() throws { key = .init() }
}
final class MemoryRegistration: PendingDeviceRegistrationStoring {
    func load(deviceKeyId: String) -> Data? { nil }
    func save(_ envelope: Data, deviceKeyId: String) {}
    func clear(deviceKeyId: String) {}
}
struct RemoteProfile: Equatable { let uuid: String }
enum SyncReconfigurationStrings { static let returnToSettings = "Return to settings" }
enum PhiSyncLog { static func describe(_ error: Error) -> String { String(describing: error) } }
func AppLogInfo(_ value: String) {}
func AppLogWarn(_ value: String) {}
func AppLogError(_ value: String) {}
@MainActor final class ProfilePairingGate {
    static let shared = ProfilePairingGate()
    var isPaired = false
    func beginEnrollment() throws {}
}
@MainActor final class SyncKeyController {
    var isRetired = false
    var requiresReconfiguration = false
}

actor JoinAPI: KeyEnvelopeAPI {
    var requests: [String: JoinRequestDTO] = [:]
    var counter = 0
    var registrations = 0
    var failDeny = false
    var tooManyPending = false
    var holdPost = false
    var postContinuation: CheckedContinuation<Void, Never>?
    var holdGet = false
    var getContinuation: CheckedContinuation<Void, Never>?
    func configure(holdPost: Bool = false, holdGet: Bool = false, failDeny: Bool = false,
                   tooManyPending: Bool = false) {
        self.holdPost = holdPost; self.holdGet = holdGet; self.failDeny = failDeny
        self.tooManyPending = tooManyPending
    }
    func releasePost() { holdPost = false; postContinuation?.resume(); postContinuation = nil }
    func releaseGet() { holdGet = false; getContinuation?.resume(); getContinuation = nil }
    func pendingIDs() -> Set<String> { Set(requests.values.filter { $0.status == "pending" }.map(\.requestId)) }
    func setStatus(_ id: String, _ status: String, envelope: Data = Data()) throws {
        guard let old = requests[id] else { throw JoinRequestError.notFound }
        requests[id] = JoinRequestDTO(requestId: id, requestingPublicKey: old.requestingPublicKey,
            name: old.name, platform: old.platform, status: status, grantedArkEnvelope: envelope,
            createdAt: old.createdAt, resolvedByDeviceKeyId: nil)
    }
    func listDevices() async throws -> [AccountDeviceDTO] { [] }
    func putAccount(salt: Data, kdfVersion: String, kdfParams: Data, recoveryEnvelope: Data) async throws -> Bool { true }
    func getAccount() async throws -> AccountKeyStateDTO? { nil }
    func postDevice(deviceKeyId: String, publicKey: Data, name: String, platform: String, arkEnvelope: Data?) async throws { registrations += 1 }
    func getDeviceEnvelope(deviceKeyId: String) async throws -> Data? { nil }
    func revokeDevice(deviceKeyId: String) async throws {}
    func postJoinRequest(publicKey: Data, name: String, platform: String) async throws -> String {
        if tooManyPending { throw JoinRequestError.tooManyPending }
        counter += 1
        let id = "join-\(counter)"
        requests[id] = JoinRequestDTO(requestId: id, requestingPublicKey: publicKey, name: name, platform: platform,
            status: "pending", grantedArkEnvelope: Data(), createdAt: Date(), resolvedByDeviceKeyId: nil)
        if holdPost { await withCheckedContinuation { postContinuation = $0 } }
        return id
    }
    func listPendingJoinRequests() async throws -> [JoinRequestSummaryDTO] {
        requests.values.filter { $0.status == "pending" }.map {
            JoinRequestSummaryDTO(requestId: $0.requestId, requestingPublicKey: $0.requestingPublicKey,
                name: $0.name, platform: $0.platform, status: $0.status, createdAt: $0.createdAt)
        }
    }
    func getJoinRequest(id: String) async throws -> JoinRequestDTO {
        guard let dto = requests[id] else { throw JoinRequestError.notFound }
        if holdGet { await withCheckedContinuation { getContinuation = $0 } }
        return dto
    }
    func approveJoinRequest(id: String, grantedArkEnvelope: Data, resolvedByDeviceKeyId: String) async throws {
        try setStatus(id, "approved", envelope: grantedArkEnvelope)
    }
    func denyJoinRequest(id: String) async throws {
        if failDeny { throw URLError(.notConnectedToInternet) }
        guard let dto = requests[id] else { throw JoinRequestError.notFound }
        guard dto.status == "pending" else { throw JoinRequestError.notPending }
        try setStatus(id, "denied")
    }
    func listProfiles() async throws -> [ProfileSummaryDTO] { [] }
    func getProfileKey(uuid: String) async throws -> ProfileKeyDTO? { nil }
    func putProfileKey(uuid: String, envelope: Data) async throws -> Bool { true }
    func getDomainKey(domain: String) async throws -> Data? { nil }
    func putDomainKey(domain: String, envelope: Data) async throws -> Bool { true }
}

@main struct JoinTests {
    static func require(_ ok: Bool, _ message: String) throws {
        if !ok { throw NSError(domain: message, code: 1) }
    }
    static func eventually(_ message: String, _ predicate: () async -> Bool) async throws {
        for _ in 0..<500 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        throw NSError(domain: message, code: 1)
    }
    @MainActor static func main() async throws {
        let api = JoinAPI(), provider = DeviceKeyStore()
        let manager = AccountKeyManager(api: api, deviceKeyProvider: provider, pendingRegistrations: MemoryRegistration())
        let vm = KeyLayerViewModel(manager: manager, beginEnrollment: {})
        await vm.startJoinRequest()
        vm.cancelJoin()
        try await eventually("Cancel must withdraw the server request") { await api.pendingIDs().isEmpty }
        await vm.startJoinRequest()
        vm.showRecoveryEntry()
        try await eventually("Recovery entry must withdraw the server request") { await api.pendingIDs().isEmpty }
        await vm.startJoinRequest()
        vm.cancelFlow()
        try await eventually("Closing setup must withdraw the server request") { await api.pendingIDs().isEmpty }

        // Requests left by an older build or a failed cancellation must not accumulate.
        let own = provider.key.publicKey.rawRepresentation
        _ = try await api.postJoinRequest(publicKey: own, name: "Sansa", platform: "macos")
        _ = try await api.postJoinRequest(publicKey: own, name: "Sansa", platform: "macos")
        let other = try await api.postJoinRequest(publicKey: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation,
                                               name: "Sansa", platform: "macos")
        let ticket = try await manager.requestJoinApproval()
        try require(await api.pendingIDs() == [other, ticket.requestId], "Replace only pending requests with this exact device public key")

        await api.configure(failDeny: true)
        let before = await api.counter
        do { _ = try await manager.requestJoinApproval(); throw NSError(domain: "Must fail when withdrawal fails", code: 1) }
        catch is URLError {}
        try require(await api.counter == before, "Failed withdrawal must not create another request")
        await api.configure()

        // Cancellation while POST is suspended must also withdraw its late response.
        await api.configure(holdPost: true)
        let old = Task { await vm.startJoinRequest() }
        try await eventually("POST must suspend") { await api.postContinuation != nil }
        vm.cancelJoin()
        let replacement = Task { await vm.startJoinRequest() }
        await api.releasePost()
        await old.value
        await replacement.value
        try require(await api.pendingIDs().count == 2, "Fast restart must leave only the other device and the current request")
        guard case .waitingForApproval = vm.phase else { throw NSError(domain: "Replacement must wait for approval", code: 1) }

        // A delayed approved GET from a cancelled request must not register/unlock this device.
        let current = await api.pendingIDs().subtracting([other]).first!
        let envelope = try PhiKeyCrypto.sealToPublicKey(Data(count: 32), recipient: provider.key.publicKey)
        try await api.setStatus(current, "approved", envelope: envelope)
        await api.configure(holdGet: true)
        let poll = Task { await vm.pollOnce() }
        try await eventually("GET must suspend") { await api.getContinuation != nil }
        vm.cancelJoin()
        await api.releaseGet()
        await poll.value
        try require(await api.registrations == 0 && manager.currentARK == nil, "Cancelled approval response must not enroll the device")
        try require(vm.phase == .chooseJoinMethod, "Cancelled poll cannot advance setup")
        // The surviving request must still complete the ordinary approval flow.
        await vm.startJoinRequest()
        let final = await api.pendingIDs().subtracting([other]).first!
        try await api.setStatus(final, "approved", envelope: envelope)
        await vm.pollOnce()
        try require(vm.phase == .readyToPair && manager.currentARK != nil, "Current approval must advance to matching")
        try require(await api.registrations == 1, "Only the current approval may register this device")

        // A full server-side request queue is not a connection failure: retrying the same
        // request cannot help, so the user is pointed at the recovery code instead.
        let freshAPI = JoinAPI()
        let fresh = KeyLayerViewModel(manager: AccountKeyManager(api: freshAPI, deviceKeyProvider: DeviceKeyStore(),
                                                                 pendingRegistrations: MemoryRegistration()),
                                      beginEnrollment: {})
        await freshAPI.configure(tooManyPending: true)
        await fresh.startJoinRequest()
        try require(fresh.phase == .error(KeyLayerStrings.tooManyJoinRequests), "Too many pending requests must keep its own message")
        // Retry from an error re-derives the route. An account no device has initialized
        // must return to first-device setup, not to a join choice where nothing can work.
        await freshAPI.configure()
        await fresh.retrySetup()
        try require(fresh.phase == .introduction, "Retry on an uninitialized account must return to first-device setup")
        print("PASS join lifecycle: cancel/recovery/close, stale tickets, exact-key isolation, failed withdrawal, late POST, cancelled approval, too-many-pending, retry routing")
    }
}

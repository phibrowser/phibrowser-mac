import CryptoKit
import Foundation

// Compile the real ProfileKeyManager with in-memory transport and persistence.
struct ProfileKeyDTO { let profileKeyEnvelope: Data }
struct ProfileSummaryDTO { let profileUuid: String }
protocol KeyEnvelopeAPI {
    func putProfileKey(uuid: String, envelope: Data) async throws -> Bool
    func getProfileKey(uuid: String) async throws -> ProfileKeyDTO?
    func listProfiles() async throws -> [ProfileSummaryDTO]
    func revokeDevice(deviceKeyId: String) async throws
}
enum AccountKeyError: Error { case randomGenerationFailed(Int32) }
final class AccountKeyManager { var currentARK: SymmetricKey? = SymmetricKey(size: .bits256) }
final class CandidateAPI: KeyEnvelopeAPI {
    var envelopes: [String: Data] = [:]
    var failure: Error?
    var beforeGet: (() -> Void)?
    func putProfileKey(uuid: String, envelope: Data) async throws -> Bool {
        if let failure { throw failure }
        envelopes[uuid] = envelope
        return true
    }
    func getProfileKey(uuid: String) async throws -> ProfileKeyDTO? {
        beforeGet?()
        if let failure { throw failure }
        return envelopes[uuid].map { ProfileKeyDTO(profileKeyEnvelope: $0) }
    }
    func listProfiles() async throws -> [ProfileSummaryDTO] {
        if let failure { throw failure }
        return envelopes.keys.sorted().map { ProfileSummaryDTO(profileUuid: $0) }
    }
    func revokeDevice(deviceKeyId: String) async throws {}
}
final class CandidateMappings: ProfileSyncMappingStore {
    var map: [String: String] = [:]
    func globalUuid(forProfileId id: String) -> String? { map[id] }
    func setGlobalUuid(_ uuid: String, forProfileId id: String) -> Bool { map[id] = uuid; return true }
    func allMappings() -> [String: String] { map }
    func removeMapping(forProfileId id: String) { map.removeValue(forKey: id) }
    func removeAllMappings() { map = [:] }
}
struct PairingLocal: Equatable { let profileId: String; let displayName: String }
enum CandidatePhase {
    case working, pairingProfiles(locals: [PairingLocal], remotes: [RemoteProfile]), error(String)
}
struct PairingLoadTimedOut: Error {}
enum PairingWizardStrings { static let profileLoadFailed = "Profile load failed" }
final class PairingLoadController {
    let profileKeys: ProfileKeyManager
    var isRetired = false
    init(_ keys: ProfileKeyManager) { profileKeys = keys }
    func localProfiles() -> [(profileId: String, displayName: String)] {
        [("Default", "Your Phi"), ("Profile 1", "Test Profile"), ("Profile 2", "Valid")]
    }
    func noteUndecryptableRemote(_ uuid: String) {}
    func noteDecryptableRemote(_ uuid: String) {}
}
final class ProfileCandidatesFixture {
    var phase = CandidatePhase.working
    let loadDeadline: Duration = .seconds(1)
    /* PRODUCTION_PAIRING_LOAD */
    /* PRODUCTION_DEADLINE */
    func load(_ controller: PairingLoadController) async { await runPairingLoad(controller: controller) }
}

func testCandidatesAfterServerReset() async throws {
    let api = CandidateAPI(), account = AccountKeyManager(), store = CandidateMappings()
    let keys = ProfileKeyManager(api: api, keyManager: account, mappingStore: store)
    for (uuid, name) in [("new-default", "Your Phi"), ("new-test", "Test Profile"), ("valid", "Valid")] {
        api.envelopes[uuid] = try ProfileKeyManager.sealProfilePayload(key: Data(repeating: 7, count: 32), name: name, ark: account.currentARK!)
    }
    store.map = ["Default": "old-default", "Profile 1": "old-test", "Profile 2": "valid"]
    let original = store.map
    let fixture = ProfileCandidatesFixture(), controller = PairingLoadController(keys)
    await fixture.load(controller)
    guard case .pairingProfiles(let locals, let remotes) = fixture.phase,
          locals.map(\.profileId) == ["Default", "Profile 1"],
          remotes.map(\.uuid) == ["new-default", "new-test"] else {
        throw NSError(domain: "ProfileCandidatesRegression", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Stale mappings hid existing local profiles after server reset"])
    }
    precondition(store.map == original, "Loading must not change mappings")
    _ = try await keys.adoptRemoteProfile(uuid: "new-default", forLocalProfile: "Default")
    precondition(store.map["Default"] == "new-default")
    await fixture.load(controller)
    guard case .pairingProfiles(let remaining, let unclaimed) = fixture.phase else { preconditionFailure() }
    precondition(remaining.map(\.profileId) == ["Profile 1"] && unclaimed.map(\.uuid) == ["new-test"])
    api.failure = URLError(.notConnectedToInternet)
    await fixture.load(controller)
    guard case .error = fixture.phase else { preconditionFailure("A failed refresh must not reuse candidates") }
    precondition(store.map["Profile 1"] == "old-test" && store.map["Profile 2"] == "valid")
    print("PASS profile candidates: stale mappings, valid mapping exclusion, adoption, read-only load, failed refresh")
}

func testRegistrationAfterServerReset() async throws {
    let api = CandidateAPI(), account = AccountKeyManager(), store = CandidateMappings()
    let keys = ProfileKeyManager(api: api, keyManager: account, mappingStore: store)
    store.map["Default"] = "removed"
    let record = try await keys.registerLocalProfile(profileId: "Default", displayName: "Your Phi")
    precondition(record.uuid != "removed" && store.map["Default"] == record.uuid)
    let opened = try ProfileKeyManager.openProfilePayload(api.envelopes[record.uuid]!, ark: account.currentARK!)
    precondition(opened.name == "Your Phi")
    do {
        _ = try await keys.registerLocalProfile(profileId: "Default", displayName: "Your Phi")
        preconditionFailure("A valid mapping must refuse duplicate registration")
    } catch ProfileKeyManagerError.alreadyMapped {}
    precondition(api.envelopes.count == 1)
    store.map["Profile 1"] = "unknown"
    api.failure = URLError(.notConnectedToInternet)
    do {
        _ = try await keys.registerLocalProfile(profileId: "Profile 1", displayName: "Test Profile")
        preconditionFailure("Lookup failure is not proof that an old mapping is gone")
    } catch is URLError {}
    precondition(store.map["Profile 1"] == "unknown" && api.envelopes.count == 1)
    api.failure = nil
    api.beforeGet = { store.map["Profile 1"] = "concurrently-adopted" }
    do {
        _ = try await keys.registerLocalProfile(profileId: "Profile 1", displayName: "Test Profile")
        preconditionFailure("A late missing response must not overwrite a changed mapping")
    } catch ProfileKeyManagerError.alreadyMapped {}
    precondition(store.map["Profile 1"] == "concurrently-adopted" && api.envelopes.count == 1)
    print("PASS profile registration: confirmed missing identity, valid mapping, transient error, concurrent remap")
}

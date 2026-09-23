import Combine
import CryptoKit
import Foundation

// Keep the wizard, both decision models, profile crypto/persistence, Space mapping,
// and KeyLayer's pairing methods real. Only app/transport boundaries are replaced.
struct ProfileKeyDTO { let profileKeyEnvelope: Data }
struct ProfileSummaryDTO { let profileUuid: String }
protocol KeyEnvelopeAPI {
    func putProfileKey(uuid: String, envelope: Data) async throws -> Bool
    func getProfileKey(uuid: String) async throws -> ProfileKeyDTO?
    func listProfiles() async throws -> [ProfileSummaryDTO]
    func revokeDevice(deviceKeyId: String) async throws
}
enum AccountKeyError: Error { case randomGenerationFailed(Int32) }
final class AccountKeyManager {
    var currentARK: SymmetricKey? = SymmetricKey(size: .bits256)
    var deviceKeyProviderForTesting: Self { self }
    func deviceKeyId() throws -> String { "device" }
}
final class RetryAPI: KeyEnvelopeAPI {
    var envelopes: [String: Data] = [:]
    var onPut: (() -> Void)?
    func putProfileKey(uuid: String, envelope: Data) async throws -> Bool {
        envelopes[uuid] = envelope
        onPut?()
        return true
    }
    func getProfileKey(uuid: String) async throws -> ProfileKeyDTO? { envelopes[uuid].map { ProfileKeyDTO(profileKeyEnvelope: $0) } }
    func listProfiles() async throws -> [ProfileSummaryDTO] { envelopes.keys.sorted().map { ProfileSummaryDTO(profileUuid: $0) } }
    func revokeDevice(deviceKeyId: String) async throws {}
}
final class RetryProfileStore: ProfileSyncMappingStore {
    var map: [String: String] = [:]
    func globalUuid(forProfileId id: String) -> String? { map[id] }
    func setGlobalUuid(_ uuid: String, forProfileId id: String) -> Bool { map[id] = uuid; return true }
    func allMappings() -> [String: String] { map }
    func removeMapping(forProfileId id: String) { map.removeValue(forKey: id) }
    func removeAllMappings() { map = [:] }
}
protocol SpaceSyncMappingStore {
    func syncUuid(forSpaceId id: String) -> String?
    func setSyncUuid(_ uuid: String, forSpaceId id: String) -> Bool
    func allMappings() -> [String: String]
    func removeMapping(forSpaceId id: String)
    func removeAllMappings()
}
final class RetrySpaceStore: SpaceSyncMappingStore {
    var map: [String: String] = [:]
    var failingID: String? = "LOCAL-2"
    var writes = 0
    func syncUuid(forSpaceId id: String) -> String? { map[id] }
    func setSyncUuid(_ uuid: String, forSpaceId id: String) -> Bool {
        guard id != failingID else { return false }
        map[id] = uuid; writes += 1; return true
    }
    func allMappings() -> [String: String] { map }
    func removeMapping(forSpaceId id: String) { map.removeValue(forKey: id) }
    func removeAllMappings() { map = [:] }
}
enum LocalStore { static let defaultSpaceId = "default" }
enum SpaceManager { static func isIncognitoSpaceId(_ id: String) -> Bool { false } }
enum SyncableSpaces {
    static let defaultSpaceUuid = "default-uuid", incognitoSpaceUuid = "incognito-uuid"
    static func opacityMilliUnits(_ value: Double?) -> Int64 { value.map { Int64($0 * 1000) } ?? -1 }
}
enum PhiSyncEngine { static let previewDeadlineMs = 1_000 }
enum SyncPairingPersistenceError: Error { case writeFailed }
enum SyncReconfigurationStrings { static let returnToSettings = "Return to settings" }
enum PhiSyncLog { static func describe(_ error: Error) -> String { String(describing: error) } }
func AppLogInfo(_ message: String) {}
func AppLogWarn(_ message: String) {}
func AppLogError(_ message: String) {}
@MainActor final class ProfilePairingGate {
    static let shared = ProfilePairingGate()
    var enrollmentGeneration = UUID()
    var isPaired = false
    func completeEnrollment(verifiedDeviceKeyID: String?) throws { isPaired = true }
}
@MainActor final class SyncKeyController {
    let manager = AccountKeyManager()
    let profileKeys: ProfileKeyManager
    let spaceKeys: SpaceSyncMappingManager
    var isRetired = false
    var profiles: [(profileId: String, displayName: String)] = [("Default", "Personal")]
    init(api: RetryAPI, spaceStore: RetrySpaceStore) {
        profileKeys = ProfileKeyManager(api: api, keyManager: manager, mappingStore: RetryProfileStore())
        spaceKeys = SpaceSyncMappingManager(store: spaceStore)
    }
    func localProfiles() -> [(profileId: String, displayName: String)] { profiles }
    func localProfileId(forGlobalUuid uuid: String) -> String? { profileKeys.localProfileId(forGlobalUuid: uuid) }
    func noteUndecryptableRemote(_ uuid: String) {}
    func noteDecryptableRemote(_ uuid: String) {}
    func createLocalProfileAndAdopt(uuid: String, displayName: String) async throws -> String {
        let id = "Created-\(profiles.count)"
        profiles.append((id, displayName))
        _ = try await profileKeys.adoptRemoteProfile(uuid: uuid, forLocalProfile: id)
        return id
    }
    func syncUuid(forSpaceId id: String) -> String? { spaceKeys.syncUuid(forSpaceId: id) }
    func mapSpace(_ id: String, toSyncUuid uuid: String) throws { try spaceKeys.map(spaceId: id, toSyncUuid: uuid) }
    func ensureSpaceMapped(spaceId: String) throws -> String { try spaceKeys.ensureMapped(spaceId: spaceId) }
    func resolveMappings() async {}
}
struct PairingLocal: Equatable { let profileId: String; let displayName: String }
enum KeyLayerPhase { case working, pairingProfiles(locals: [PairingLocal], remotes: [RemoteProfile]), error(String) }
struct PairingLoadTimedOut: Error {}
@MainActor final class KeyLayerViewModel {
    var phase = KeyLayerPhase.working
    var isSubmitting = false
    var pairingError: String?
    var pairingLoad: Task<Void, Never>?
    let loadDeadline: Duration = .seconds(1)
    init(manager: AccountKeyManager) {}
    /* PRODUCTION_PAIRING_METHODS */
}

@main struct PairingRetryTests {
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: message, code: 1) }
    }
    static func local(_ id: String, _ name: String) -> PhiLocalSpace {
        PhiLocalSpace(spaceId: id, profileId: "Default", name: name, colorHex: "blue", iconName: "star", sortOrder: 0,
                      createdDate: Date(timeIntervalSince1970: 0), themeId: nil, opacityLight: nil, opacityDark: nil)
    }
    static func remote(_ id: String, _ name: String) -> PhiAccountSpaceSummary {
        PhiAccountSpaceSummary(syncUuid: id, name: name, iconName: "star", colorHex: "blue", profileUuid: "remote-profile", isDefault: false,
                               themeId: "", overlayOpacityLightMilli: -1, overlayOpacityDarkMilli: -1)
    }
    enum ProfileMode { case register, adopt, create }
    enum Change { case none, serverSpace, newProfile, missingProfile, localDuringApply }
    @MainActor static func run(_ mode: ProfileMode = .register, change: Change = .none) async throws {
        let api = RetryAPI(), store = RetrySpaceStore(), gate = ProfilePairingGate()
        let controller = SyncKeyController(api: api, spaceStore: store)
        var locals = [local("LOCAL-1", "Work"), local("LOCAL-2", "Reading")]
        var account = [remote("acct-1", "Work"), remote("acct-2", "Reading")]
        if mode != .register {
            api.envelopes["remote-profile"] = try ProfileKeyManager.sealProfilePayload(
                key: Data(count: 32), name: "Remote name", ark: controller.manager.currentARK!)
        }
        let wizard = PairingWizardViewModel(keyLayer: KeyLayerViewModel(manager: controller.manager),
            previewAccountSpaces: { .success(account) }, pairableLocalSpaces: { locals }, themeDisplayName: { _ in nil }, gate: gate)
        await wizard.start(controller: controller)
        if mode == .adopt { wizard.profileSelections["Default"] = .remote("remote-profile") }
        if mode == .create { wizard.profileRemoteChoices["remote-profile"] = .createLocal }
        wizard.continueToSpaces()
        wizard.assign(.existing(syncUuid: "acct-1"), to: "LOCAL-1")
        wizard.assign(.existing(syncUuid: "acct-2"), to: "LOCAL-2")
        if change == .localDuringApply { api.onPut = { locals[1].name = "Edited locally during Profile write" } }
        await wizard.finish(controller: controller)
        guard case .error(_, .backToSpaces) = wizard.phase else { throw NSError(domain: "Expected partial Space failure", code: 1) }
        if change == .localDuringApply {
            try require(store.map.isEmpty && !gate.isPaired, "Profile progress must not accept Space edits made during its network writes")
        } else {
            try require(store.map == ["LOCAL-1": "acct-1"] && !gate.isPaired, "Partial apply must retain one mapping and keep gate shut")
        }
        store.failingID = nil
        if change == .serverSpace { account[1] = remote("acct-2", "Changed on another device") }
        if change == .newProfile {
            api.envelopes["unexpected-profile"] = try ProfileKeyManager.sealProfilePayload(
                key: Data(count: 32), name: "Unexpected", ark: controller.manager.currentARK!)
        }
        if change == .missingProfile { api.envelopes.removeAll() }
        await wizard.retry(controller: controller)
        await wizard.finish(controller: controller)
        if change != .none {
            guard case .profiles = wizard.phase else { throw NSError(domain: "Changed review must return to fresh matching", code: 1) }
            try require(store.map["LOCAL-2"] == nil && !gate.isPaired, "Changed review cannot apply outstanding decisions or complete pairing")
            return
        }
        try require(wizard.phase == .done, "Retry after own Profile registration must finish instead of discarding Space choices")
        try require(store.map == ["LOCAL-1": "acct-1", "LOCAL-2": "acct-2"], "Retry must preserve the unapplied Space choice")
        try require(api.envelopes.count == (mode == .create ? 2 : 1) && store.writes == 2 && gate.isPaired,
                    "Retry must reuse confirmed identities exactly once")
        try require(controller.profiles.count == (mode == .create ? 2 : 1), "Retry cannot duplicate created Profiles")
    }
    @MainActor static func main() async throws {
        try await run(.register)
        try await run(.adopt)
        try await run(.create)
        try await run(change: .serverSpace)
        try await run(change: .newProfile)
        try await run(change: .missingProfile)
        try await run(change: .localDuringApply)
        print("PASS pairing retry: register/adopt/create progress, retained choices, idempotence, changed server Spaces/Profiles, local edits during apply")
    }
}

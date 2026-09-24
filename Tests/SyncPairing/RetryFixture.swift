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
    func removeSpaceMapping(forSpaceId id: String) { spaceKeys.removeMapping(forSpaceId: id) }
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
    @MainActor static func sameNameSuggestions() async throws {
        let api = RetryAPI(), store = RetrySpaceStore()
        let controller = SyncKeyController(api: api, spaceStore: store)
        api.envelopes["remote-profile"] = try ProfileKeyManager.sealProfilePayload(
            key: Data(count: 32), name: "Personal", ark: controller.manager.currentARK!)
        let locals = [local("LOCAL-1", "Work"), local("LOCAL-2", "Reading")]
        let account = [remote("acct-1", "Work"), remote("acct-2", "Reading")]
        let wizard = PairingWizardViewModel(keyLayer: KeyLayerViewModel(manager: controller.manager),
            previewAccountSpaces: { .success(account) }, pairableLocalSpaces: { locals }, themeDisplayName: { _ in nil })
        await wizard.start(controller: controller)
        wizard.continueToSpaces()
        try require(wizard.spaceSelections == ["LOCAL-1": .existing(syncUuid: "acct-1"), "LOCAL-2": .existing(syncUuid: "acct-2")],
                    "Same-name Spaces in the selected Profile must be preselected")
        try require(store.map.isEmpty, "Suggestions must not persist before Finish")
        wizard.backToProfiles()
        wizard.profileSelections["Default"] = .registerNew
        wizard.profileRemoteChoices["remote-profile"] = .createLocal
        wizard.continueToSpaces()
        try require(wizard.spaceSelections.isEmpty, "Changing the chosen Profile must invalidate automatic Space suggestions")
        wizard.backToProfiles()
        wizard.profileSelections["Default"] = .remote("remote-profile")
        wizard.profileRemoteChoices = [:]
        wizard.continueToSpaces()
        wizard.assign(.addAsNew, to: "LOCAL-1")
        wizard.assign(nil, to: "LOCAL-2")
        wizard.backToProfiles()
        wizard.continueToSpaces()
        try require(wizard.spaceSelections == ["LOCAL-1": .addAsNew], "Returning to Spaces must preserve explicit choices, including Choose")
        _ = try await controller.profileKeys.adoptRemoteProfile(uuid: "remote-profile", forLocalProfile: "Default")
        store.map = ["LOCAL-1": "old-account-space"]
        await wizard.start(controller: controller)
        try require(wizard.spaceSelections == ["LOCAL-1": .existing(syncUuid: "acct-1"), "LOCAL-2": .existing(syncUuid: "acct-2")],
                    "Fresh entry must also suggest Spaces for an already-mapped Profile and a stale Space identity")
        try require(store.map == ["LOCAL-1": "old-account-space"], "A fresh suggestion must not replace a persisted identity yet")
        // Finish then replaces the stale identity instead of failing with alreadyMapped.
        store.failingID = nil
        await wizard.finish(controller: controller)
        try require(store.map == ["LOCAL-1": "acct-1", "LOCAL-2": "acct-2"],
                    "A confirmed suggestion must replace a stale Space identity")
    }
    static func ambiguousSpaceSuggestions() throws {
        func suggested(_ locals: [PhiLocalSpace], _ account: [PhiAccountSpaceSummary],
                       selections: [String: SpacePairingModel.Assignment] = [:]) -> [String: SpacePairingModel.Assignment] {
            let input = SpacePairingModel.Input(locals: locals, accountSpaces: account, localProfileNames: [:], accountProfileNames: [:])
            return SpacePairingModel(input: input, selections: selections)
                .suggestingSameNames(profileMappings: ["Default": "remote-profile"], excluding: [])
        }
        let work = local("work", "Work")
        try require(suggested([work], [remote("a", "Work"), remote("b", "Work")]).isEmpty,
                    "Duplicate account names must remain undecided")
        try require(suggested([work, local("other", "Work")], [remote("a", "Work")]).isEmpty,
                    "Duplicate local names must remain undecided")
        var otherProfile = work
        otherProfile.profileId = "Other"
        try require(suggested([otherProfile], [remote("a", "Work")]).isEmpty,
                    "Same name in an unmatched Profile cannot authorize a suggestion")
        try require(suggested([local(LocalStore.defaultSpaceId, "Work")], [remote("a", "Work")]).isEmpty,
                    "The default Space must not claim a selectable account Space")
        try require(suggested([work], [remote("a", "Renamed"), remote("b", "Work")], selections: ["work": .existing(syncUuid: "a")])
                    == ["work": .existing(syncUuid: "a")], "Stable identities outrank names")
        try require(suggested([work], [remote("a", "Work")], selections: ["work": .addAsNew])
                    == ["work": .existing(syncUuid: "a")], "Stale identity fallback may receive a same-name suggestion")
    }
    @MainActor static func main() async throws {
        try ambiguousSpaceSuggestions()
        try await sameNameSuggestions()
        try await run(.register)
        try await run(.adopt)
        try await run(.create)
        try await run(change: .serverSpace)
        try await run(change: .newProfile)
        try await run(change: .missingProfile)
        try await run(change: .localDuringApply)
        print("PASS same-name Space suggestions, ambiguity, Profile changes, explicit choices; pairing retry: register/adopt/create progress, retained choices, idempotence, changed server Spaces/Profiles, local edits during apply")
    }
}

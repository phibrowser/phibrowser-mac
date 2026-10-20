import Combine
import CryptoKit
import Foundation

// Keep the wizard, both decision models, profile crypto/persistence, Space mapping,
// and KeyLayer's pairing methods real. Only app/transport boundaries are replaced.
struct ProfileKeyDTO { let profileKeyEnvelope: Data }
struct ProfileSummaryDTO { let profileUuid: String }
protocol KeyEnvelopeAPI {
    func putProfileKey(uuid: String, envelope: Data) async throws -> Bool
    func replaceProfileKeyEnvelope(uuid: String, expected: Data, envelope: Data) async throws -> Bool
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
    func replaceProfileKeyEnvelope(uuid: String, expected: Data, envelope: Data) async throws -> Bool {
        guard envelopes[uuid] == expected else { return false }
        envelopes[uuid] = envelope
        return true
    }
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
enum LocalStore { static let defaultSpaceId = "default"; static let defaultProfileId = "Default" }
enum SpaceManager { static func isIncognitoSpaceId(_ id: String) -> Bool { false } }
enum SyncableSpaces {
    static let defaultSpaceUuid = "default-uuid", incognitoSpaceUuid = "incognito-uuid"
    static func opacityMilliUnits(_ value: Double?) -> Int64 { value.map { Int64($0 * 1000) } ?? -1 }
}
enum PhiSyncEngine { static let previewDeadlineMs = 1_000 }
/// `liveRemotes` filters preview Profile tombstones by tag hash; the derivation itself is pinned
/// elsewhere, so an identity hash is enough here.
enum PhiSyncEntity {
    static func profileClientTag(_ uuid: String) -> String { "profile:" + uuid }
    static func clientTagHash(for tag: String) -> String { tag }
}
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
    /// Mirrors the production gate's marker clearing after a persisted completion.
    var onComplete: (() -> Void)?
    func completeEnrollment(verifiedDeviceKeyID: String?) throws { isPaired = true; onComplete?() }
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
        _ = try await profileKeys.adoptRemoteProfile(uuid: uuid, forLocalProfile: id, isDefault: false)
        return id
    }
    func syncUuid(forSpaceId id: String) -> String? { spaceKeys.syncUuid(forSpaceId: id) }
    func mapSpace(_ id: String, toSyncUuid uuid: String, replacing expectedUuid: String? = nil) throws {
        try spaceKeys.map(spaceId: id, toSyncUuid: uuid, replacing: expectedUuid)
    }
    func removeSpaceMapping(forSpaceId id: String) { spaceKeys.removeMapping(forSpaceId: id) }
    func ensureSpaceMapped(spaceId: String) throws -> String { try spaceKeys.ensureMapped(spaceId: spaceId) }
    var onResolve: (() -> Void)?
    func resolveMappings() async { onResolve?() }
    var localResetMarker: SyncPairingLocalResetMarker?
    var onMarkerSaved: (() -> Void)?
    func pairingLocalResetMarker() -> SyncPairingLocalResetMarker? { localResetMarker }
    func savePairingLocalResetMarker(deleteProfileIds: Set<String>, startedAt: Date = Date()) throws {
        onMarkerSaved?()
        localResetMarker = SyncPairingLocalResetMarker(deviceKeyID: "device", deleteProfileIds: deleteProfileIds,
                                                       startedAtMs: Int64(startedAt.timeIntervalSince1970 * 1000))
    }
}
struct PairingLocal: Equatable { let profileId: String; let displayName: String; let isDefault: Bool }
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
    @MainActor static func replacementNeedsCompletePreview(initialSkipped: Int = 1) async throws {
        let api = RetryAPI(), store = RetrySpaceStore(), gate = ProfilePairingGate()
        store.failingID = nil
        store.map = ["LOCAL-1": "unreadable-account-space"]
        let controller = SyncKeyController(api: api, spaceStore: store)
        api.envelopes["remote-profile"] = try ProfileKeyManager.sealProfilePayload(
            key: Data(count: 32), name: "Personal", ark: controller.manager.currentARK!)
        _ = try await controller.profileKeys.adoptRemoteProfile(uuid: "remote-profile", forLocalProfile: "Default", isDefault: true)
        var skipped = initialSkipped
        let wizard = PairingWizardViewModel(keyLayer: KeyLayerViewModel(manager: controller.manager),
            previewAccountSpaces: { .success(.init(spaces: [remote("acct-1", "Work")], skippedEntityCount: skipped)) },
            pairableLocalSpaces: { [local("LOCAL-1", "Work")] }, themeDisplayName: { _ in nil }, gate: gate,
            methodStepEnabled: false)
        await wizard.start(controller: controller)
        skipped = 1
        if initialSkipped == 0 {
            await wizard.finish(controller: controller)
            try require(store.map == ["LOCAL-1": "unreadable-account-space"] && !gate.isPaired,
                        "A preview that becomes incomplete during preflight cannot authorize a write")
            wizard.continueToSpaces()
        }
        await wizard.finish(controller: controller)
        try require(store.map == ["LOCAL-1": "unreadable-account-space"] && !gate.isPaired,
                    "A skipped entity cannot authorize replacing a missing identity")
        guard case .error(_, .backToSpaces) = wizard.phase else {
            throw NSError(domain: "Incomplete preview must reject the replacement", code: 1)
        }
        skipped = 0
        await wizard.retry(controller: controller)
        await wizard.finish(controller: controller)
        try require(store.map == ["LOCAL-1": "unreadable-account-space"],
                    "Changed preview completeness must request fresh review first")
        wizard.continueToSpaces()
        await wizard.finish(controller: controller)
        try require(store.map == ["LOCAL-1": "acct-1"] && gate.isPaired,
                    "A fresh complete preview can authorize an atomic replacement")
    }

    @MainActor static func replacementRejectsClaimsAndChangedIdentities() throws {
        let store = RetrySpaceStore()
        store.failingID = nil
        store.map = ["LOCAL-1": "old", "LOCAL-2": "claimed"]
        let manager = SpaceSyncMappingManager(store: store)
        do {
            try manager.map(spaceId: "LOCAL-1", toSyncUuid: "claimed", replacing: "old")
            throw NSError(domain: "Duplicate identity must be rejected", code: 1)
        } catch SpaceSyncMappingError.syncUuidAlreadyClaimed {}
        try require(store.map == ["LOCAL-1": "old", "LOCAL-2": "claimed"],
                    "A rejected claim must preserve the original mapping")
        do {
            try manager.map(spaceId: "LOCAL-1", toSyncUuid: "new", replacing: "outdated")
            throw NSError(domain: "A changed identity must be rejected", code: 1)
        } catch SpaceSyncMappingError.alreadyMapped {}
        try require(store.map["LOCAL-1"] == "old", "Replacement must compare the reviewed identity")
    }
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
            previewAccountSpaces: { .success(.init(spaces: account, skippedEntityCount: 0)) }, pairableLocalSpaces: { locals }, themeDisplayName: { _ in nil }, gate: gate,
            methodStepEnabled: false)
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
            previewAccountSpaces: { .success(.init(spaces: account, skippedEntityCount: 0)) }, pairableLocalSpaces: { locals }, themeDisplayName: { _ in nil },
            methodStepEnabled: false)
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
        _ = try await controller.profileKeys.adoptRemoteProfile(uuid: "remote-profile", forLocalProfile: "Default", isDefault: true)
        store.map = ["LOCAL-1": "old-account-space"]
        await wizard.start(controller: controller)
        try require(wizard.spaceSelections == ["LOCAL-1": .existing(syncUuid: "acct-1"), "LOCAL-2": .existing(syncUuid: "acct-2")],
                    "Fresh entry must also suggest Spaces for an already-mapped Profile and a stale Space identity")
        try require(store.map == ["LOCAL-1": "old-account-space"], "A fresh suggestion must not replace a persisted identity yet")
        // Failed replacement must preserve the old identity until one durable write succeeds.
        store.failingID = "LOCAL-1"
        await wizard.finish(controller: controller)
        try require(store.map == ["LOCAL-1": "old-account-space"],
                    "A failed replacement must retain the prior Space identity")
        await wizard.retry(controller: controller)
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
    // MARK: - Use your account's data (the merge cases above pin the method step off)

    /// Records the replace sequence; `failures` makes that many clear() calls throw.
    final class EventLog { var events: [String] = [] }
    @MainActor final class FakeReset: LocalPhiResetting {
        let log: EventLog
        var failures = 0
        var pairedAtClear: [Bool] = []
        var clearRequests: [LocalResetRequest] = []
        var inventory = LocalPhiInventory(nonDefaultSpaceIds: ["LOCAL-1"], bookmarks: 3, pinnedTabs: 1)
        let gate: ProfilePairingGate
        let controller: SyncKeyController
        let onCleared: () -> Void
        init(gate: ProfilePairingGate, controller: SyncKeyController, log: EventLog = EventLog(),
             onCleared: @escaping () -> Void) {
            self.gate = gate; self.controller = controller; self.log = log; self.onCleared = onCleared
        }
        func inventory(deleting profileIds: Set<String>) throws -> LocalPhiInventory { inventory }
        func clear(_ request: LocalResetRequest) async throws {
            log.events.append("clear")
            pairedAtClear.append(gate.isPaired)
            clearRequests.append(request)
            if failures > 0 { failures -= 1; throw NSError(domain: "clear stopped", code: 1) }
            controller.profiles.removeAll { request.deleteProfileIds.contains($0.profileId) }
            inventory = LocalPhiInventory()
            onCleared()
        }
    }

    /// Default + one junk Profile (deleted without any choice) + a "Work" Profile that matches the account's
    /// "Work" Profile by name (adopted, never deleted). Clear fails once: Retry converges.
    @MainActor static func replaceRunsInOrderAndRetryConverges() async throws {
        let api = RetryAPI(), store = RetrySpaceStore(), gate = ProfilePairingGate()
        store.failingID = nil
        let controller = SyncKeyController(api: api, spaceStore: store)
        controller.profiles = [("Default", "Personal"), ("Profile 2", "Junk"), ("Profile 3", "Work")]
        let ark = controller.manager.currentARK!
        api.envelopes["acct-default"] = try ProfileKeyManager.sealProfilePayload(
            key: Data(count: 32), name: "Your Phi", isDefault: true, ark: ark)
        api.envelopes["acct-work"] = try ProfileKeyManager.sealProfilePayload(
            key: Data(count: 32), name: "Work", isDefault: false, ark: ark)
        var locals = [local(LocalStore.defaultSpaceId, "Default"), local("LOCAL-1", "Junk Space")]
        let log = EventLog()
        api.onPut = { log.events.append("registered") }
        controller.onMarkerSaved = {
            // Adopting writes nothing to the account: the Profile decisions show as mappings at marker time.
            if controller.profileKeys.mappedGlobalUuid(forProfileId: "Profile 3") != nil { log.events.append("profiles") }
            log.events.append("marker")
        }
        controller.onResolve = { log.events.append("resolve") }
        let reset = FakeReset(gate: gate, controller: controller, log: log, onCleared: { locals = [locals[0]] })
        reset.failures = 1
        gate.onComplete = { log.events.append("enrollment"); controller.localResetMarker = nil }
        let wizard = PairingWizardViewModel(keyLayer: KeyLayerViewModel(manager: controller.manager),
            previewAccountSpaces: { .success(.init(spaces: [remote("acct-1", "Work")], skippedEntityCount: 0)) },
            pairableLocalSpaces: { locals }, themeDisplayName: { _ in nil }, gate: gate,
            localReset: { _ in reset })
        await wizard.start(controller: controller)
        guard case .method(let summary) = wizard.phase else { throw NSError(domain: "Expected the method step", code: 1) }
        try require(summary.local.bookmarks == 3 && summary.local.profiles == 3 && summary.account.spaces == 2,
                    "The method step counts both sides")
        try require(wizard.visibleSteps.first == .method && !wizard.methodStepFinishes, "Merge continues to its pages")
        wizard.selectedMethod = .useAccount
        try require(wizard.visibleSteps == [.method, .confirm], "The step bar follows the selected method")
        await wizard.continueFromMethod(controller: controller)
        guard case .confirmReplaceLocal(let review) = wizard.phase else {
            throw NSError(domain: "Expected the replace confirmation", code: 1)
        }
        try require(review.extraLocals.map(\.profileId) == ["Profile 2"] && !review.defaultUnavailable,
                    "Only the unmatched local Profile is listed; the same-name one is matched")
        try require(review.removed.profiles == 1 && review.removed.spaces == 1 && review.removed.bookmarks == 3,
                    "Removed counts come from the inventory and the deleted Profiles")

        // Clear fails once: the gate stays unpaired with the marker written, and nothing else completes.
        await wizard.replaceLocal(controller: controller)
        guard case .error(_, .resumeReplace) = wizard.phase else {
            throw NSError(domain: "Expected the replace error, got \(wizard.phase)", code: 1)
        }
        try require(!gate.isPaired && controller.localResetMarker?.deleteProfileIds == ["Profile 2"],
                    "A stopped clear keeps the gate shut and the marker set")
        try require(wizard.methodLocked, "Once the marker is written the method is locked")

        await wizard.retry(controller: controller)
        try require(wizard.phase == .done && gate.isPaired, "Retry converges")
        try require(reset.clearRequests == [LocalResetRequest(deleteProfileIds: ["Profile 2"]),
                                            LocalResetRequest(deleteProfileIds: ["Profile 2"])],
                    "Clear runs twice, deleting the extra Profile")
        try require(reset.pairedAtClear == [false, false], "Clear always runs before enrollment")
        try require(controller.localResetMarker == nil, "Completion clears the marker")
        try require(controller.profileKeys.mappedGlobalUuid(forProfileId: "Profile 3") == "acct-work"
                    && controller.profileKeys.mappedGlobalUuid(forProfileId: "Profile 2") == nil,
                    "The same-name Profile adopts its account Profile and the deleted one is never registered")
        try require(controller.localProfileId(forGlobalUuid: "acct-default") == "Default",
                    "The Default adopts the account default")
        try require(store.map.isEmpty, "Replacing maps no Space")
        try require(api.envelopes.count == 2, "No Profile is registered with the account")
        try require(log.events == ["profiles", "marker", "clear", "profiles", "marker", "clear", "enrollment", "resolve"],
                    "Order: Profiles, marker, clear, then enrollment and resolve; got \(log.events)")
    }

    /// A marker from an earlier session lands on a locked confirmation that lists its saved deletions.
    @MainActor static func aMarkerResumesTheLockedConfirmation() async throws {
        let api = RetryAPI(), store = RetrySpaceStore(), gate = ProfilePairingGate()
        store.failingID = nil
        let controller = SyncKeyController(api: api, spaceStore: store)
        controller.profiles = [("Default", "Personal"), ("Profile 2", "Junk")]
        try controller.savePairingLocalResetMarker(deleteProfileIds: ["Profile 2"])
        var locals = [local(LocalStore.defaultSpaceId, "Default")]
        let reset = FakeReset(gate: gate, controller: controller, onCleared: { locals = [locals[0]] })
        reset.inventory = LocalPhiInventory()
        let wizard = PairingWizardViewModel(keyLayer: KeyLayerViewModel(manager: controller.manager),
            previewAccountSpaces: { .success(.init(spaces: [remote("acct-1", "Work")], skippedEntityCount: 0)) },
            pairableLocalSpaces: { locals }, themeDisplayName: { _ in nil }, gate: gate,
            localReset: { _ in reset })
        await wizard.start(controller: controller)
        guard case .confirmReplaceLocal(let review) = wizard.phase else {
            throw NSError(domain: "Expected the locked confirmation, got \(wizard.phase)", code: 1)
        }
        try require(review.extraLocals.map(\.profileId) == ["Profile 2"] && review.removed.profiles == 1,
                    "The saved deletion is shown")
        try require(wizard.methodLocked && !wizard.canGoBackToMethod && wizard.selectedMethod == .useAccount,
                    "The resumed confirmation is locked without Back")
        wizard.backToMethod()
        guard case .confirmReplaceLocal = wizard.phase else { throw NSError(domain: "Back is refused", code: 1) }
        // Finish later keeps the marker.
        try require(wizard.leaveWithoutApplying() && controller.localResetMarker != nil
                    && wizard.selectedMethod == .merge && !wizard.methodLocked,
                    "Leaving discards the page state but keeps the marker")
        await wizard.start(controller: controller)
        await wizard.replaceLocal(controller: controller)
        try require(wizard.phase == .done && gate.isPaired, "The resumed replace completes")
        try require(reset.clearRequests == [LocalResetRequest(deleteProfileIds: ["Profile 2"])],
                    "The marker's deletions are used")
    }

    @MainActor static func main() async throws {
        try ambiguousSpaceSuggestions()
        try await replacementNeedsCompletePreview()
        try await replacementNeedsCompletePreview(initialSkipped: 0)
        try replacementRejectsClaimsAndChangedIdentities()
        try await sameNameSuggestions()
        try await run(.register)
        try await run(.adopt)
        try await run(.create)
        try await run(change: .serverSpace)
        try await run(change: .newProfile)
        try await run(change: .missingProfile)
        try await run(change: .localDuringApply)
        try await replaceRunsInOrderAndRetryConverges()
        try await aMarkerResumesTheLockedConfirmation()
        print("PASS replace: order, clear failure then Retry, locked resume, Finish later keeps the marker;  same-name Space suggestions, ambiguity, Profile changes, explicit choices; pairing retry: register/adopt/create progress, retained choices, idempotence, changed server Spaces/Profiles, local edits during apply")
    }
}

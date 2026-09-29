import CryptoKit
import Foundation

// The production mapping pass, auto-create, repair pass and key delivery of
// SyncKeyController, with the real ProfileKeyManager, envelope crypto and pause
// predicate. Only the transport, the bridge and logging are replaced.
/* PRODUCTION_NOTIFICATIONS */
/* PRODUCTION_PROFILE_CREATING */
/* PRODUCTION_REFRESH_OUTCOME */
/* PRODUCTION_KEY_API_ERROR */
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
enum PhiSyncLog { static func describe(_ error: Error) -> String { String(describing: error) } }
func AppLogInfo(_ message: String) {}
func AppLogWarn(_ message: String) {}

final class PassAPI: KeyEnvelopeAPI {
    var envelopes: [String: Data] = [:]
    var putError: Error?
    var puts: [String] = []
    var onGet: ((String) async -> Void)?
    var getErrors: [String: Error] = [:]
    func putProfileKey(uuid: String, envelope: Data) async throws -> Bool {
        if let putError { throw putError }
        puts.append(uuid)
        envelopes[uuid] = envelope
        return true
    }
    func getProfileKey(uuid: String) async throws -> ProfileKeyDTO? {
        await onGet?(uuid)
        if let error = getErrors[uuid] { throw error }
        return envelopes[uuid].map { ProfileKeyDTO(profileKeyEnvelope: $0) }
    }
    func listProfiles() async throws -> [ProfileSummaryDTO] { envelopes.keys.sorted().map { ProfileSummaryDTO(profileUuid: $0) } }
    func revokeDevice(deviceKeyId: String) async throws {}
}
final class PassMappingStore: ProfileSyncMappingStore {
    var map: [String: String] = [:]
    func globalUuid(forProfileId id: String) -> String? { map[id] }
    func setGlobalUuid(_ uuid: String, forProfileId id: String) -> Bool { map[id] = uuid; return true }
    func allMappings() -> [String: String] { map }
    func removeMapping(forProfileId id: String) { map.removeValue(forKey: id) }
    func removeAllMappings() { map = [:] }
}
final class PassProfileCreator: LocalProfileCreating {
    var profiles: [(profileId: String, displayName: String)] = []
    var createResults: [String?] = []
    private(set) var createCalls: [String] = []
    var userAssignableProfileIds: [(profileId: String, displayName: String)] { profiles }
    func displayNameExists(_ name: String) -> Bool {
        profiles.contains { $0.displayName.caseInsensitiveCompare(name) == .orderedSame }
    }
    func createProfile(displayName: String) async -> String? {
        createCalls.append(displayName)
        await Task.yield()
        let result = createResults.isEmpty ? "Created \(createCalls.count)" : createResults.removeFirst()
        if let result { profiles.append((profileId: result, displayName: displayName)) }
        return result
    }
}

@MainActor
final class SyncKeyController {
    let profileKeys: ProfileKeyManager
    private let localProfilesProvider: () -> [(profileId: String, displayName: String)]
    private let notifyChromium: () -> Void
    private let profileCreator: any LocalProfileCreating
    private let isPairingComplete: @MainActor () -> Bool
    init(profileKeys: ProfileKeyManager, creator: PassProfileCreator, paired: @escaping @MainActor () -> Bool = { true }) {
        self.profileKeys = profileKeys
        localProfilesProvider = { creator.userAssignableProfileIds }
        notifyChromium = {}
        profileCreator = creator
        isPairingComplete = paired
    }
    /* PRODUCTION_PASS_STATE */
    /* PRODUCTION_KEY_DELIVERY */
    /* PRODUCTION_PASSES */
}

@main
struct MappingPassTests {
    @MainActor final class Stack {
        let api = PassAPI()
        let manager = AccountKeyManager()
        let store = PassMappingStore()
        let creator = PassProfileCreator()
        let controller: SyncKeyController
        var outcomes: [String] = []
        var events: [String] = []
        private var tokens: [NSObjectProtocol] = []
        init() {
            controller = SyncKeyController(
                profileKeys: ProfileKeyManager(api: api, keyManager: manager, mappingStore: store), creator: creator)
            tokens.append(NotificationCenter.default.addObserver(
                forName: .phiProfileMappingsDidResolve, object: nil, queue: nil) { [unowned self] note in
                    MainActor.assumeIsolated {
                        outcomes.append(note.userInfo?[SyncKeyController.mappingsOutcomeKey] as? String ?? "none")
                        events.append("resolve")
                    }
                })
            tokens.append(NotificationCenter.default.addObserver(
                forName: .phiProfileAutoCreateDidRun, object: nil, queue: nil) { [unowned self] _ in
                    MainActor.assumeIsolated { events.append("autocreate") }
                })
        }
        func close() { for token in tokens { NotificationCenter.default.removeObserver(token) } }
        /// An account Profile registered by another device, unmapped here.
        func seedRemote(_ uuid: String, name: String) throws {
            api.envelopes[uuid] = try ProfileKeyManager.sealProfilePayload(
                key: Data(repeating: 7, count: 32), name: name, ark: manager.currentARK!)
        }
        /// A local Profile already mapped to its own account Profile.
        func seedMappedLocal(_ id: String, uuid: String) throws {
            creator.profiles.append((profileId: id, displayName: id))
            try seedRemote(uuid, name: id)
            store.map[id] = uuid
        }
        func pause() -> SyncProfileMappingPause {
            SyncProfileMappingPause.evaluate(
                syncableProfileIds: creator.profiles.map(\.profileId), persistedMappings: store.map,
                lastMeasuredUnmappedProfileIds: controller.lastMeasuredUnmappedProfileIds,
                profileIdsBeingCreated: controller.profileIdsBeingCreated,
                lastPassResult: controller.lastMappingsPassResult)
        }
    }

    @MainActor static func main() async throws {
        try await noCountBasedAdopt()
        try await twinAdopted()
        try await transientRegisterFailureHolds()
        try await definitiveRegisterFailure()
        try await undecryptableRemoteDoesNotBlock()
        try await deletedLocalMappingDoesNotBlock()
        try await repairOrder()
        try await keyWithdrawal()
        try await creationIsTracked()
        try await autoCreateIsSingleFlight()
        try await capCountsAttempts()
        print("PASS mapping pass: no count-based adopt, twin adopt, transient held, definitive class, undecryptable and deleted-local remotes do not block, repair order, key withdrawal, creation tracking, single-flight auto-create, attempt cap")
    }

    /// D20: one new local beside one new account Profile is not a match. Neither
    /// the pass nor the repair merges them; the repair creates a local for the
    /// account Profile and then registers the new local as its own account Profile.
    @MainActor static func noCountBasedAdopt() async throws {
        let s = Stack(); defer { s.close() }
        try s.seedMappedLocal("Default", uuid: "uuid-default")
        s.creator.profiles.append((profileId: "Profile 2", displayName: "Home"))
        try s.seedRemote("uuid-work", name: "Work")
        await s.controller.resolveMappings()
        precondition(s.store.map["Profile 2"] == nil, "A lone new local was merged by count")
        precondition(s.api.puts.isEmpty, "A claimable account Profile must hold registration until auto-create had its turn")
        precondition(s.controller.lastMeasuredUnmappedProfileIds == ["Profile 2"])
        precondition(s.controller.lastMappingsPassResult == .measured)
        precondition(s.pause().reason == .registering && s.pause().unmappedProfileIds == ["Profile 2"])

        await s.controller.runMappingRepairPass()
        let created = s.creator.profiles.first { $0.displayName == "Work" }
        precondition(created != nil && s.store.map[created!.profileId] == "uuid-work")
        let registered = s.store.map["Profile 2"]
        precondition(registered != nil && registered != "uuid-work" && s.api.puts == [registered!],
                     "The new local must be registered as a new account Profile (R4)")
        precondition(s.controller.lastMeasuredUnmappedProfileIds == [] && s.controller.lastMappingsPassResult == .measured)
        precondition(!s.pause().isPaused)
        precondition(s.controller.profileSyncInfo(forProfileId: "Profile 2")?.uuid == registered)
    }

    /// D20 keeps the same-name twin search: the repair adopts rather than registers.
    @MainActor static func twinAdopted() async throws {
        let s = Stack(); defer { s.close() }
        try s.seedMappedLocal("Default", uuid: "uuid-default")
        s.creator.profiles.append((profileId: "Profile 2", displayName: "Home"))
        try s.seedRemote("uuid-home", name: "home")
        await s.controller.runMappingRepairPass()
        precondition(s.store.map["Profile 2"] == "uuid-home", "A same-named unmapped local must be adopted")
        precondition(s.creator.createCalls.isEmpty && s.api.puts.isEmpty)
        precondition(!s.pause().isPaused)
    }

    @MainActor static func transientRegisterFailureHolds() async throws {
        for error in [KeyAPIError.http(503, ""), KeyAPIError.http(401, ""),
                      KeyAPIError.transport(URLError(.notConnectedToInternet))] as [Error] {
            let s = Stack(); defer { s.close() }
            try s.seedMappedLocal("Default", uuid: "uuid-default")
            await s.controller.resolveMappings()
            precondition(s.controller.lastMeasuredUnmappedProfileIds == [])
            s.creator.profiles.append((profileId: "Profile 2", displayName: "Home"))
            s.api.putError = error
            await s.controller.resolveMappings()
            precondition(s.outcomes.last == "held", "A transient registration failure must not measure")
            precondition(s.controller.lastMappingsPassResult == .heldTransient)
            precondition(s.controller.lastMeasuredUnmappedProfileIds == [], "A held pass keeps the last measured set")
            precondition(s.controller.profileSyncInfo(forProfileId: "Default") != nil, "Mapped Profiles keep their keys")
            precondition(s.pause().reason == .retrying && s.pause().unmappedProfileIds == ["Profile 2"])
            s.api.putError = nil
            await s.controller.resolveMappings()
            precondition(s.outcomes.last == "measured" && s.store.map["Profile 2"] != nil && !s.pause().isPaused)
        }
    }

    @MainActor static func definitiveRegisterFailure() async throws {
        let s = Stack(); defer { s.close() }
        try s.seedMappedLocal("Default", uuid: "uuid-default")
        s.creator.profiles.append((profileId: "Profile 2", displayName: "Home"))
        s.api.putError = KeyAPIError.http(400, "")
        await s.controller.resolveMappings()
        precondition(s.outcomes.last == "measured")
        precondition(s.controller.lastMappingsPassResult == .definitiveFailure)
        precondition(s.controller.lastMeasuredUnmappedProfileIds == ["Profile 2"])
        precondition(s.pause().reason == .needsAttention)
        precondition(SyncKeyController.mappingFailureResult(for: ProfileKeyManagerError.badEnvelope) == .definitiveFailure)
        precondition(SyncKeyController.mappingFailureResult(for: PhiKeyCryptoError.decryptFailed) == .definitiveFailure)
        precondition(SyncKeyController.mappingFailureResult(for: ProfileKeyManagerError.notUnlocked) == .heldTransient)
        precondition(SyncKeyController.mappingFailureResult(for: KeyAPIError.http(403, "")) == .heldTransient)
        precondition(SyncKeyController.mappingFailureResult(for: KeyAPIError.http(404, "")) == .definitiveFailure)
    }

    /// A4: an account Profile whose envelope does not open cannot be claimed by the
    /// twin search, so once auto-create has recorded it, it no longer holds
    /// registration of a new local.
    @MainActor static func undecryptableRemoteDoesNotBlock() async throws {
        let s = Stack(); defer { s.close() }
        try s.seedMappedLocal("Default", uuid: "uuid-default")
        s.creator.profiles.append((profileId: "Profile 2", displayName: "Home"))
        s.api.envelopes["uuid-broken"] = Data([0x01, 0x02, 0x03])
        await s.controller.runMappingRepairPass()
        precondition(s.controller.undecryptableRemoteUuids == ["uuid-broken"])
        precondition(s.creator.createCalls.isEmpty)
        let registered = s.store.map["Profile 2"]
        precondition(registered != nil && registered != "uuid-broken" && s.api.puts == [registered!])
        precondition(!s.pause().isPaused)
    }

    /// Deviation recorded in the plan: a uuid the persisted mapping gives to a
    /// deleted local is never grown back, so it must not hold registration either.
    @MainActor static func deletedLocalMappingDoesNotBlock() async throws {
        let s = Stack(); defer { s.close() }
        try s.seedMappedLocal("Default", uuid: "uuid-default")
        try s.seedRemote("uuid-deleted", name: "Old")
        s.store.map["Profile 9"] = "uuid-deleted"
        s.creator.profiles.append((profileId: "Profile 2", displayName: "Home"))
        await s.controller.runMappingRepairPass()
        precondition(s.creator.createCalls.isEmpty, "A deleted local's account Profile grew back")
        precondition(s.store.map["Profile 2"] != nil && s.store.map["Profile 2"] != "uuid-deleted")
    }

    /// Auto-create runs before the mapping pass, and a dead mapping heals onto its
    /// own uuid through the twin search instead of forking a new account Profile.
    @MainActor static func repairOrder() async throws {
        let s = Stack(); defer { s.close() }
        try s.seedMappedLocal("Default", uuid: "uuid-default")
        s.events = []
        await s.controller.runMappingRepairPass()
        precondition(s.events == ["autocreate", "resolve"], "Repair must run auto-create first: \(s.events)")

        s.store.map["Default"] = nil   // §6.2 A0 dropped the mapping; the account Profile is still there
        await s.controller.runMappingRepairPass()
        precondition(s.store.map["Default"] == "uuid-default" && s.api.puts.isEmpty,
                     "A dropped mapping must heal onto its own uuid, not fork")

        // Locked: both halves decline, nothing is written.
        s.store.map["Default"] = nil
        s.manager.currentARK = nil
        await s.controller.runMappingRepairPass()
        precondition(s.store.map["Default"] == nil && s.controller.lastMappingsPassResult == .heldTransient)

        // Enrollment incomplete: auto-create is skipped, the pass registers nothing.
        let gated = Stack(); defer { gated.close() }
        let controller = SyncKeyController(
            profileKeys: ProfileKeyManager(api: gated.api, keyManager: gated.manager, mappingStore: gated.store),
            creator: gated.creator, paired: { false })
        gated.creator.profiles.append((profileId: "Profile 2", displayName: "Home"))
        try gated.seedRemote("uuid-work", name: "Work")
        await controller.runMappingRepairPass()
        precondition(gated.creator.createCalls.isEmpty && gated.api.puts.isEmpty)
    }

    @MainActor static func keyWithdrawal() async throws {
        let s = Stack(); defer { s.close() }
        try s.seedMappedLocal("Default", uuid: "uuid-default")
        try s.seedMappedLocal("Profile 1", uuid: "uuid-one")
        await s.controller.resolveMappings()
        let before = ["Default", "Profile 1"].map { s.controller.profileSyncInfo(forProfileId: $0) }
        precondition(before.allSatisfy { $0 != nil })
        s.controller.chromiumKeysWithdrawn = true
        precondition(["Default", "Profile 1"].allSatisfy { s.controller.profileSyncInfo(forProfileId: $0) == nil })
        await s.controller.resolveMappings()
        precondition(s.controller.profileSyncInfo(forProfileId: "Default") == nil, "A pass must not undo the withdrawal")
        s.controller.chromiumKeysWithdrawn = false
        let after = ["Default", "Profile 1"].map { s.controller.profileSyncInfo(forProfileId: $0) }
        precondition(zip(before, after).allSatisfy { $0?.uuid == $1?.uuid && $0?.passphrase == $1?.passphrase })
    }

    /// A Profile the key layer creates is in `profileIdsBeingCreated` while its adopt
    /// runs, leaves it afterwards, and after a failed adopt counts as unmapped at once.
    @MainActor static func creationIsTracked() async throws {
        let s = Stack(); defer { s.close() }
        try s.seedMappedLocal("Default", uuid: "uuid-default")
        try s.seedRemote("uuid-work", name: "Work")
        final class Seen: @unchecked Sendable {
            var creating: Set<String> = []
            var pause: SyncProfileMappingPause?
        }
        let seen = Seen()
        // The adopt's GET is the second one for this uuid (after auto-create's name
        // lookup); fail exactly that one, and look at the pause while it runs.
        s.api.onGet = { uuid in
            guard uuid == "uuid-work" else { return }
            await MainActor.run {
                guard !s.controller.profileIdsBeingCreated.isEmpty else { return }
                seen.creating = s.controller.profileIdsBeingCreated
                seen.pause = s.pause()
                s.api.getErrors["uuid-work"] = KeyAPIError.http(503, "")
            }
        }
        _ = await s.controller.ensureLocalProfilesForAccount()
        let created = s.creator.profiles.first { $0.displayName == "Work" }!.profileId
        precondition(seen.creating == [created] && seen.pause?.isPaused == false,
                     "The pause must ignore a Profile while its adopt runs")
        precondition(s.controller.profileIdsBeingCreated.isEmpty)
        precondition(s.outcomes.last == "held", "A failed adopt must announce")
        precondition(s.pause().unmappedProfileIds == [created], "A failed adopt counts at once")
        await s.controller.resolveMappings()
        precondition(s.controller.lastMappingsPassResult == .heldTransient,
                     "The auto-create failure explains the waiting registration")

        s.api.onGet = nil
        s.api.getErrors = [:]
        _ = await s.controller.ensureLocalProfilesForAccount()
        precondition(s.store.map[created] == "uuid-work" && s.creator.createCalls.count == 1,
                     "The retry re-adopts the Profile it already created")
        precondition(!s.pause().isPaused && s.controller.lastMappingsPassResult == .measured)
    }

    @MainActor static func autoCreateIsSingleFlight() async throws {
        let s = Stack(); defer { s.close() }
        try s.seedRemote("uuid-work", name: "Work")
        async let first = s.controller.ensureLocalProfilesForAccount()
        async let second: Void = s.controller.runMappingRepairPass()
        _ = await (first, second)
        precondition(s.creator.createCalls == ["Work"], "Two rounds created a Profile each: \(s.creator.createCalls)")
    }

    /// BH-16: failing creates still stop at the cap.
    @MainActor static func capCountsAttempts() async throws {
        let s = Stack(); defer { s.close() }
        for index in 1...5 { try s.seedRemote("uuid-\(index)", name: "P\(index)") }
        s.creator.createResults = [nil, nil, nil, nil, nil]
        _ = await s.controller.ensureLocalProfilesForAccount()
        precondition(s.creator.createCalls.count == SyncKeyController.maxAutoCreatesPerRound)
        precondition(s.controller.lastMappingsPassResult == nil)
    }
}

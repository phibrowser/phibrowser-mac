import CryptoKit
import XCTest
@testable import Phi

@MainActor
final class ProfileAutoCreateTests: XCTestCase {
    typealias FakeAPI = AccountKeyManagerTests.FakeAPI
    typealias FakeDeviceKeyProvider = AccountKeyManagerTests.FakeDeviceKeyProvider
    typealias MemoryMappingStore = ProfileKeyManagerTests.MemoryMappingStore

    /// A reference cell for what a `NotificationCenter` observer records. The
    /// block is `@Sendable`, so capturing a plain `var` of a non-`Sendable` type
    /// (`[AnyHashable: Any]?`) warns. `@unchecked` is sound here and nowhere
    /// else: every observer below is registered with `queue: nil`, so it runs
    /// synchronously on the posting thread, and every poster is the main actor.
    final class Box<T>: @unchecked Sendable {
        var value: T
        init(_ value: T) { self.value = value }
    }

    final class FakeProfileCreator: LocalProfileCreating {
        var profiles: [(profileId: String, displayName: String)] = []
        /// Extra names visible to `displayNameExists` but NOT user-assignable:
        /// the agent fallback profile lives here.
        var reservedNames: [String] = []
        var createResults: [String?] = []
        private(set) var createCalls: [String] = []
        /// Runs inside `createProfile`'s suspension, the way `$profiles` would.
        var duringCreate: (() -> Void)?

        var userAssignableProfileIds: [(profileId: String, displayName: String)] { profiles }
        func displayNameExists(_ name: String) -> Bool {
            (profiles.map(\.displayName) + reservedNames)
                .contains { $0.caseInsensitiveCompare(name) == .orderedSame }
        }
        func createProfile(displayName: String) async -> String? {
            createCalls.append(displayName)
            duringCreate?()
            let result = createResults.isEmpty ? "P\(createCalls.count)" : createResults.removeFirst()
            if let result { profiles.append((profileId: result, displayName: displayName)) }
            return result
        }
    }

    private func stack(creator: FakeProfileCreator,
                       store: MemoryMappingStore = MemoryMappingStore())
    async throws -> (FakeAPI, AccountKeyManager, SyncKeyController, MemoryMappingStore) {
        let api = FakeAPI()
        let mgr = AccountKeyManager(api: api, deviceKeyProvider: FakeDeviceKeyProvider())
        _ = try await mgr.bootstrap()
        let pkm = ProfileKeyManager(api: api, keyManager: mgr, mappingStore: store)
        let approvals = DeviceApprovalService(api: api, keyManager: mgr,
                                              deviceKeyProvider: FakeDeviceKeyProvider())
        let controller = SyncKeyController(
            manager: mgr, approvals: approvals, profileKeys: pkm,
            localProfilesProvider: { creator.userAssignableProfileIds },
            notifyChromium: {}, profileCreator: creator)
        return (api, mgr, controller, store)
    }

    /// Registers a profile on the account "from another device": an envelope
    /// exists, but this Mac has no mapping for it.
    private func seedRemoteProfile(_ api: FakeAPI, _ mgr: AccountKeyManager,
                                   uuid: String, name: String) throws {
        var key = Data(count: 32)
        key[0] = 7
        api.profileEnvelopes[uuid] = try ProfileKeyManager.sealProfilePayload(
            key: key, name: name, ark: mgr.currentARK!)
    }

    func testAnAccountProfileWithNoLocalCounterpartIsCreatedAndAdopted() async throws {
        let creator = FakeProfileCreator()
        let (api, mgr, controller, store) = try await stack(creator: creator)
        try seedRemoteProfile(api, mgr, uuid: "uuid-work", name: "Work")

        let pings = Box(0)
        let token = NotificationCenter.default.addObserver(
            forName: .phiProfileMappingsDidResolve, object: nil, queue: nil) { _ in pings.value += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        let outcome = await controller.ensureLocalProfilesForAccount()
        XCTAssertEqual(outcome, .changed)
        XCTAssertEqual(creator.createCalls, ["Work"])
        XCTAssertEqual(store.map.values.sorted(), ["uuid-work"])
        // The wrap-up resolve is what puts the new passphrase in `resolved` and
        // pings Chromium; without it the profile exists but never syncs, and
        // nothing retries because the mapping now exists.
        XCTAssertGreaterThanOrEqual(pings.value, 1)
        XCTAssertNotNil(controller.profileSyncInfo(forProfileId: creator.profiles[0].profileId))
    }

    func testASteadyStateRoundSendsOneListAndCreatesNothing() async throws {
        let creator = FakeProfileCreator()
        let store = MemoryMappingStore()
        let (api, mgr, controller, _) = try await stack(creator: creator, store: store)
        try seedRemoteProfile(api, mgr, uuid: "uuid-work", name: "Work")
        store.map = ["P1": "uuid-work"]
        creator.profiles = [(profileId: "P1", displayName: "Work")]

        let listsBefore = api.listProfilesCalls
        let getsBefore = api.getProfileKeyCalls
        let outcome = await controller.ensureLocalProfilesForAccount()
        XCTAssertEqual(outcome, .unchanged)
        XCTAssertEqual(api.listProfilesCalls - listsBefore, 1)
        XCTAssertEqual(api.getProfileKeyCalls - getsBefore, 0, "steady state is ONE small GET")
        XCTAssertTrue(creator.createCalls.isEmpty)
    }

    func testAFailedListMakesNoChangesAtAll() async throws {
        struct Offline: Error {}
        let creator = FakeProfileCreator()
        let (api, mgr, controller, store) = try await stack(creator: creator)
        try seedRemoteProfile(api, mgr, uuid: "uuid-work", name: "Work")
        api.listProfilesError = Offline()
        let outcome = await controller.ensureLocalProfilesForAccount()
        XCTAssertEqual(outcome, .failed)
        XCTAssertTrue(creator.createCalls.isEmpty)
        XCTAssertTrue(store.map.isEmpty)
    }

    func testAnUndecryptableEnvelopeIsSkippedNotGuessed() async throws {
        let creator = FakeProfileCreator()
        let (api, _, controller, store) = try await stack(creator: creator)
        api.profileEnvelopes["uuid-broken"] = Data([0x00, 0x01])
        let info = Box<[AnyHashable: Any]?>(nil)
        let token = NotificationCenter.default.addObserver(
            forName: .phiProfileAutoCreateDidRun, object: nil, queue: nil) { info.value = $0.userInfo }
        defer { NotificationCenter.default.removeObserver(token) }

        let outcome = await controller.ensureLocalProfilesForAccount()
        XCTAssertEqual(outcome, .unchanged)
        XCTAssertTrue(creator.createCalls.isEmpty, "a profile with no per-profile key is useless")
        XCTAssertTrue(store.map.isEmpty)
        XCTAssertEqual(info.value?["skippedUuids"] as? Int, 1)
        XCTAssertTrue(controller.undecryptableRemoteUuids.contains("uuid-broken"))
    }

    /// The retry path: last round created the profile but `adoptRemoteProfile`
    /// failed, so no mapping was written and a same-named unmapped profile is
    /// sitting there. Adopt it; do NOT create a second one every minute.
    func testAnExistingUnmappedSameNamedProfileIsAdoptedInsteadOfCreated() async throws {
        let creator = FakeProfileCreator()
        creator.profiles = [(profileId: "P1", displayName: "Work")]
        let (api, mgr, controller, store) = try await stack(creator: creator)
        try seedRemoteProfile(api, mgr, uuid: "uuid-work", name: "Work")

        let outcome = await controller.ensureLocalProfilesForAccount()
        XCTAssertEqual(outcome, .changed)
        XCTAssertTrue(creator.createCalls.isEmpty)
        XCTAssertEqual(store.map["P1"], "uuid-work")
    }

    func testTheAgentFallbackProfileIsNeverAdoptedButStillForcesASuffix() async throws {
        let creator = FakeProfileCreator()
        creator.reservedNames = [PhiPreferences.AgentSpaces.agentFallbackProfileName]
        let (api, mgr, controller, store) = try await stack(creator: creator)
        try seedRemoteProfile(api, mgr, uuid: "uuid-agent",
                              name: PhiPreferences.AgentSpaces.agentFallbackProfileName)
        _ = await controller.ensureLocalProfilesForAccount()
        XCTAssertEqual(creator.createCalls,
                       ["\(PhiPreferences.AgentSpaces.agentFallbackProfileName) (2)"])
        XCTAssertFalse(store.map.keys.contains("agent-fallback"))
    }

    func testACollidingDisplayNameGetsASuffix() async throws {
        let creator = FakeProfileCreator()
        creator.profiles = [(profileId: "P1", displayName: "Work")]
        let (api, mgr, controller, store) = try await stack(creator: creator)
        store.map = ["P1": "uuid-existing"]
        try seedRemoteProfile(api, mgr, uuid: "uuid-existing", name: "Work")
        try seedRemoteProfile(api, mgr, uuid: "uuid-other", name: "Work")
        _ = await controller.ensureLocalProfilesForAccount()
        XCTAssertEqual(creator.createCalls, ["Work (2)"])
    }

    /// The leak the same-named twin search cannot cover. `adoptRemoteProfile`
    /// writes the mapping only after the envelope opens, so a blip inside it
    /// leaves the just-created profile unmapped -- and because the name collided,
    /// that profile is called "Work (2)" while the twin search looks for "Work".
    /// Without the pending-create record every failed round would leave one more
    /// empty profile behind, and `resolveMappings()` would eventually push each
    /// of them to the account as a brand-new profile.
    func testAFailedAdoptReusesTheProfileItAlreadyCreatedInsteadOfLeakingIt() async throws {
        struct Offline: Error {}
        let creator = FakeProfileCreator()
        creator.profiles = [(profileId: "P1", displayName: "Work")]
        creator.createResults = ["P9"]
        let (api, mgr, controller, store) = try await stack(creator: creator)
        store.map = ["P1": "uuid-existing"]
        try seedRemoteProfile(api, mgr, uuid: "uuid-existing", name: "Work")
        try seedRemoteProfile(api, mgr, uuid: "uuid-other", name: "Work")

        // The failure lands in `adoptRemoteProfile`'s GET, not in the
        // `remoteProfile(uuid:)` that precedes the create -- arming it inside the
        // create's suspension is the only way to hit exactly that window.
        creator.duringCreate = { api.profileEndpointError = Offline() }
        let first = await controller.ensureLocalProfilesForAccount()
        XCTAssertEqual(first, .unchanged)
        XCTAssertEqual(creator.createCalls, ["Work (2)"])
        XCTAssertFalse(store.map.values.contains("uuid-other"), "the adopt threw, so no mapping")

        creator.duringCreate = nil
        api.profileEndpointError = nil
        let second = await controller.ensureLocalProfilesForAccount()
        XCTAssertEqual(second, .changed)
        XCTAssertEqual(creator.createCalls, ["Work (2)"],
                       "the second round must re-adopt onto P9, never create a third profile")
        XCTAssertEqual(store.map["P9"], "uuid-other")
    }

    /// The pending record is a hint, not a promise: a profile the user deleted
    /// while the adopt was failing must not be adopted, and the round has to fall
    /// back to creating a fresh one.
    func testAPendingProfileDeletedBeforeTheRetryIsNotAdopted() async throws {
        struct Offline: Error {}
        let creator = FakeProfileCreator()
        creator.profiles = [(profileId: "P1", displayName: "Work")]
        creator.createResults = ["P9", "P10"]
        let (api, mgr, controller, store) = try await stack(creator: creator)
        store.map = ["P1": "uuid-existing"]
        try seedRemoteProfile(api, mgr, uuid: "uuid-existing", name: "Work")
        try seedRemoteProfile(api, mgr, uuid: "uuid-other", name: "Work")

        creator.duringCreate = { api.profileEndpointError = Offline() }
        _ = await controller.ensureLocalProfilesForAccount()
        XCTAssertEqual(creator.createCalls, ["Work (2)"])

        creator.duringCreate = nil
        api.profileEndpointError = nil
        creator.profiles.removeAll { $0.profileId == "P9" }
        let second = await controller.ensureLocalProfilesForAccount()
        XCTAssertEqual(second, .changed)
        XCTAssertEqual(creator.createCalls, ["Work (2)", "Work (2)"],
                       "P9 is gone, so its name is free again and a fresh create is correct")
        XCTAssertEqual(store.map["P10"], "uuid-other")
    }

    func testThrottleCapsCreationsPerRound() async throws {
        let creator = FakeProfileCreator()
        let (api, mgr, controller, _) = try await stack(creator: creator)
        for i in 1...5 { try seedRemoteProfile(api, mgr, uuid: "uuid-\(i)", name: "P\(i)") }
        let info = Box<[AnyHashable: Any]?>(nil)
        let token = NotificationCenter.default.addObserver(
            forName: .phiProfileAutoCreateDidRun, object: nil, queue: nil) { info.value = $0.userInfo }
        defer { NotificationCenter.default.removeObserver(token) }
        _ = await controller.ensureLocalProfilesForAccount()
        XCTAssertEqual(creator.createCalls.count, 3)
        XCTAssertEqual(info.value?["created"] as? Int, 3)
        XCTAssertEqual(info.value?["skippedUuids"] as? Int, 2)
    }

    func testALockedArkOrAPendingJoinSendsNoRequestAtAll() async throws {
        let creator = FakeProfileCreator()
        let api = FakeAPI()
        let locked = AccountKeyManager(api: api, deviceKeyProvider: FakeDeviceKeyProvider())
        let pkm = ProfileKeyManager(api: api, keyManager: locked, mappingStore: MemoryMappingStore())
        let approvals = DeviceApprovalService(api: api, keyManager: locked,
                                              deviceKeyProvider: FakeDeviceKeyProvider())
        let controller = SyncKeyController(manager: locked, approvals: approvals, profileKeys: pkm,
                                           localProfilesProvider: { [] }, notifyChromium: {},
                                           profileCreator: creator)
        let lockedOutcome = await controller.ensureLocalProfilesForAccount()
        XCTAssertEqual(lockedOutcome, .failed)
        XCTAssertEqual(api.listProfilesCalls, 0)

        // The other half of §12.1 ⑧, and §11's 口径: a shut gate is `.skipped`,
        // NOT `.failed` -- it does not arm the retry and it is reported as
        // `profile_refresh=skipped`.
        ProfilePairingGate.staticPendingOverride = true
        defer { ProfilePairingGate.staticPendingOverride = nil }
        let payload = Box<[AnyHashable: Any]?>(nil)
        let token = NotificationCenter.default.addObserver(
            forName: .phiProfileAutoCreateDidRun, object: nil, queue: nil) { payload.value = $0.userInfo }
        defer { NotificationCenter.default.removeObserver(token) }
        let gatedOutcome = await controller.ensureLocalProfilesForAccount()
        XCTAssertEqual(gatedOutcome, .skipped)
        XCTAssertEqual(api.listProfilesCalls, 0)
        XCTAssertEqual(payload.value?["outcome"] as? String, "skipped")
    }

    /// The one suspension in the round is `createProfile`; `$profiles` runs a
    /// `resolveMappings()` pass inside it, whose 1:1 branch can claim the very
    /// uuid being worked on. Re-checking afterwards is what keeps two locals from
    /// mapping to one uuid.
    func testAUuidClaimedDuringTheSuspensionIsNotAdoptedTwice() async throws {
        let creator = FakeProfileCreator()
        let store = MemoryMappingStore()
        let (api, mgr, controller, _) = try await stack(creator: creator, store: store)
        try seedRemoteProfile(api, mgr, uuid: "uuid-work", name: "Work")
        creator.duringCreate = { store.map["P0"] = "uuid-work" }
        _ = await controller.ensureLocalProfilesForAccount()
        XCTAssertEqual(store.map.filter { $0.value == "uuid-work" }.count, 1)
    }

    /// nil has three causes (empty/duplicate name, bridge missing, bridge
    /// failure). Treating it as "duplicate, try another suffix" turns a missing
    /// bridge into unbounded suffix probing.
    func testABridgeFailureIsOneAttemptAndOneSkip() async throws {
        let creator = FakeProfileCreator()
        creator.createResults = [nil]
        let (api, mgr, controller, store) = try await stack(creator: creator)
        try seedRemoteProfile(api, mgr, uuid: "uuid-work", name: "Work")
        let info = Box<[AnyHashable: Any]?>(nil)
        let token = NotificationCenter.default.addObserver(
            forName: .phiProfileAutoCreateDidRun, object: nil, queue: nil) { info.value = $0.userInfo }
        defer { NotificationCenter.default.removeObserver(token) }
        _ = await controller.ensureLocalProfilesForAccount()
        XCTAssertEqual(creator.createCalls.count, 1)
        XCTAssertEqual(info.value?["skippedUuids"] as? Int, 1)
        XCTAssertTrue(store.map.isEmpty)
    }

    func testAnEmptyRegisteredNameFallsBackToProfile() async throws {
        let creator = FakeProfileCreator()
        let (api, mgr, controller, _) = try await stack(creator: creator)
        try seedRemoteProfile(api, mgr, uuid: "uuid-blank", name: "")
        _ = await controller.ensureLocalProfilesForAccount()
        XCTAssertEqual(creator.createCalls, ["Profile"])
    }
}

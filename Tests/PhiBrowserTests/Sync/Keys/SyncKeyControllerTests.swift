import XCTest
import CryptoKit
@testable import Phi

@MainActor
final class SyncKeyControllerTests: XCTestCase {
    typealias FakeAPI = AccountKeyManagerTests.FakeAPI
    typealias FakeDeviceKeyProvider = AccountKeyManagerTests.FakeDeviceKeyProvider
    typealias MemoryMappingStore = ProfileKeyManagerTests.MemoryMappingStore

    /// Primary factory: the locals list is resolved per call (so a test can
    /// grow it between passes) and the mapping store is injectable (so a test
    /// can seed or wipe a mapping the way a real device would).
    private func makeController(api: FakeAPI, provider: FakeDeviceKeyProvider,
                                localsProvider: @escaping () -> [(profileId: String, displayName: String)],
                                store: ProfileSyncMappingStore = MemoryMappingStore(),
                                pinged: @escaping () -> Void = {}) -> (SyncKeyController, AccountKeyManager) {
        let mgr = AccountKeyManager(api: api, deviceKeyProvider: provider)
        let pkm = ProfileKeyManager(api: api, keyManager: mgr, mappingStore: store)
        let approvals = DeviceApprovalService(api: api, keyManager: mgr, deviceKeyProvider: provider)
        let c = SyncKeyController(manager: mgr, approvals: approvals, profileKeys: pkm,
                                  localProfilesProvider: localsProvider,
                                  notifyChromium: pinged)
        return (c, mgr)
    }

    private func makeController(api: FakeAPI, provider: FakeDeviceKeyProvider,
                                locals: [(String, String)],
                                pinged: @escaping () -> Void = {}) -> (SyncKeyController, AccountKeyManager) {
        makeController(api: api, provider: provider,
                       localsProvider: { locals.map { (profileId: $0.0, displayName: $0.1) } },
                       pinged: pinged)
    }

    func testFirstDeviceRegistersAllLocalsAndPings() async throws {
        let api = FakeAPI()
        let provider = FakeDeviceKeyProvider()
        _ = try await AccountKeyManager(api: api, deviceKeyProvider: provider).bootstrap() // device joined, no profiles yet
        var pings = 0
        let (c, _) = makeController(api: api, provider: provider,
                                    locals: [("Default", "Default"), ("Profile 1", "Work")],
                                    pinged: { pings += 1 })
        await c.silentUnlockAndResolve()
        XCTAssertEqual(c.resolved.count, 2)
        XCTAssertFalse(c.needsPairing)
        XCTAssertEqual(api.profileEnvelopes.count, 2)
        XCTAssertEqual(pings, 1)
        XCTAssertNotNil(c.profileSyncInfo(forProfileId: "Default"))
        XCTAssertEqual(c.profileSyncInfo(forProfileId: "Default")!.passphrase.count, 64)
    }

    func testSingleRemoteSingleLocalAutoAdopts() async throws {
        let api = FakeAPI()
        // Device A bootstraps and registers one profile.
        let providerA = FakeDeviceKeyProvider()
        let mgrA = AccountKeyManager(api: api, deviceKeyProvider: providerA)
        _ = try await mgrA.bootstrap()
        let pkmA = ProfileKeyManager(api: api, keyManager: mgrA, mappingStore: MemoryMappingStore())
        let recA = try await pkmA.registerLocalProfile(profileId: "Default", displayName: "Work")
        // Device B joins with the recovery-equivalent (same account) and has one local profile.
        let providerB = FakeDeviceKeyProvider()
        let mgrBSeed = AccountKeyManager(api: api, deviceKeyProvider: providerB)
        // Seed device B's envelope by sealing the ARK to it (reuse approval-style seal).
        let arkBytes = mgrA.currentARK!.withUnsafeBytes { Data($0) }
        let sealed = try PhiKeyCrypto.sealToPublicKey(arkBytes, recipient: providerB.loadOrCreatePrivateKey().publicKey)
        try await api.postDevice(deviceKeyId: providerB.deviceKeyId(), publicKey: providerB.loadOrCreatePrivateKey().publicKey.rawRepresentation,
                                 name: "B", platform: "macos", arkEnvelope: sealed)
        _ = mgrBSeed // silence unused
        let (c, _) = makeController(api: api, provider: providerB, locals: [("Default", "Default")])
        await c.silentUnlockAndResolve()
        XCTAssertFalse(c.needsPairing)
        XCTAssertEqual(c.profileSyncInfo(forProfileId: "Default")?.uuid, recA.uuid)
        XCTAssertEqual(c.profileSyncInfo(forProfileId: "Default")?.passphrase, recA.passphrase)
    }

    func testAmbiguousSetsNeedsPairing() async throws {
        let api = FakeAPI()
        let providerA = FakeDeviceKeyProvider()
        let mgrA = AccountKeyManager(api: api, deviceKeyProvider: providerA)
        _ = try await mgrA.bootstrap()
        let pkmA = ProfileKeyManager(api: api, keyManager: mgrA, mappingStore: MemoryMappingStore())
        _ = try await pkmA.registerLocalProfile(profileId: "Default", displayName: "Work")
        _ = try await pkmA.registerLocalProfile(profileId: "Profile 1", displayName: "Home")
        // Same device, wiped mapping (fresh controller with empty store): 2 remotes, 1 local -> pairing.
        let (c, _) = makeController(api: api, provider: providerA, locals: [("Default", "Default")])
        await c.silentUnlockAndResolve()
        XCTAssertTrue(c.needsPairing)
        XCTAssertNil(c.profileSyncInfo(forProfileId: "Default"))
    }

    func testNotSignedInLeavesEmpty() async throws {
        let api = FakeAPI()
        api.deviceEnvelopeError = KeyAPIError.http(401, "")
        let (c, _) = makeController(api: api, provider: FakeDeviceKeyProvider(), locals: [("Default", "Default")])
        await c.silentUnlockAndResolve()
        XCTAssertTrue(c.resolved.isEmpty)
        XCTAssertFalse(c.needsPairing)
    }

    // MARK: - C-1: transient failures must never read as "definitively absent"

    /// A 5xx on the per-profile lookup is "unknown", not "unmapped". The
    /// previously resolved entry survives and, critically, no second UUID is
    /// minted for a profile that already owns one.
    func testTransientProfileLookupFailurePreservesEntryAndDoesNotRegister() async throws {
        let api = FakeAPI()
        let provider = FakeDeviceKeyProvider()
        _ = try await AccountKeyManager(api: api, deviceKeyProvider: provider).bootstrap()
        var pings = 0
        let (c, _) = makeController(api: api, provider: provider,
                                    locals: [("Default", "Default")],
                                    pinged: { pings += 1 })
        await c.silentUnlockAndResolve()
        let before = try XCTUnwrap(c.profileSyncInfo(forProfileId: "Default"))
        XCTAssertEqual(api.profileEnvelopes.count, 1)
        XCTAssertEqual(pings, 1)

        api.profileEndpointError = KeyAPIError.http(503, "")
        await c.resolveMappings()

        let after = try XCTUnwrap(c.profileSyncInfo(forProfileId: "Default"))
        XCTAssertEqual(after.uuid, before.uuid, "transient failure must not re-namespace the profile")
        XCTAssertEqual(after.passphrase, before.passphrase)
        XCTAssertEqual(api.profileEnvelopes.count, 1, "no fresh uuid may be registered on a transient failure")
        XCTAssertFalse(c.needsPairing)
    }

    /// With the remote profile set unknown, the pass aborts before any
    /// register/adopt decision: the cache stands untouched and the previous
    /// answer is held; the pass still pings and still announces so the gates
    /// see a state update.
    func testAccountProfilesFailureAbortsPassKeepingCache() async throws {
        let api = FakeAPI()
        let provider = FakeDeviceKeyProvider()
        _ = try await AccountKeyManager(api: api, deviceKeyProvider: provider).bootstrap()
        var pings = 0
        let store = MemoryMappingStore()
        var locals = [(profileId: "Default", displayName: "Default")]
        let (c, _) = makeController(api: api, provider: provider,
                                    localsProvider: { locals }, store: store,
                                    pinged: { pings += 1 })
        await c.silentUnlockAndResolve()
        let before = try XCTUnwrap(c.profileSyncInfo(forProfileId: "Default"))
        XCTAssertEqual(pings, 1)
        let envelopesBefore = api.profileEnvelopes.count

        // A second local profile appears while the account listing is down.
        locals.append((profileId: "Profile 1", displayName: "Work"))
        api.listProfilesError = KeyAPIError.transport(URLError(.notConnectedToInternet))
        await c.resolveMappings()

        XCTAssertEqual(c.resolved.count, 1, "aborted pass must not replace the cache")
        XCTAssertEqual(c.profileSyncInfo(forProfileId: "Default")?.uuid, before.uuid)
        XCTAssertNil(c.profileSyncInfo(forProfileId: "Profile 1"))
        XCTAssertEqual(api.profileEnvelopes.count, envelopesBefore, "no registration with an unknown remote set")
        XCTAssertEqual(pings, 2, "the bail-out re-pings the live cache rather than going silent")
    }

    // MARK: - D3: the second disjunct, the actionable split, and the held answer

    func testNeedsPairingIsTrueWhenTheAccountHasAProfileThisMacDoesNot() async throws {
        let api = FakeAPI()
        let provider = FakeDeviceKeyProvider()
        let mgr = AccountKeyManager(api: api, deviceKeyProvider: provider)
        _ = try await mgr.bootstrap()
        let store = MemoryMappingStore()
        // Every local is mapped; the account still holds one more profile.
        let pkm = ProfileKeyManager(api: api, keyManager: mgr, mappingStore: store)
        let mine = try await pkm.registerLocalProfile(profileId: "Default", displayName: "Default")
        let theirs = try await pkm.registerLocalProfile(profileId: "temp", displayName: "Work")
        store.removeMapping(forProfileId: "temp")

        let getsBefore = api.getProfileKeyCalls
        let (c, _) = makeController(api: api, provider: provider,
                                    localsProvider: { [(profileId: "Default", displayName: "Default")] },
                                    store: store)
        await c.silentUnlockAndResolve()
        XCTAssertTrue(c.needsPairing, "an unclaimed account profile is the second disjunct")
        XCTAssertTrue(c.needsPairingActionable)
        XCTAssertEqual(api.getProfileKeyCalls - getsBefore, 1,
                       "only the mapped local's own lookup; the remote SET must not pay 1+N")
        XCTAssertNotEqual(mine.uuid, theirs.uuid)
    }

    func testATransientRemoteFailureHoldsThePreviousAnswerAndStillAnnounces() async throws {
        let api = FakeAPI()
        let provider = FakeDeviceKeyProvider()
        _ = try await AccountKeyManager(api: api, deviceKeyProvider: provider).bootstrap()
        let (c, _) = makeController(api: api, provider: provider,
                                    localsProvider: { [(profileId: "Default", displayName: "Default")] })
        await c.silentUnlockAndResolve()          // registers "Default"; needsPairing == false
        var announcements = 0
        let token = NotificationCenter.default.addObserver(
            forName: .phiProfileMappingsDidResolve, object: nil, queue: nil) { _ in announcements += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        struct Offline: Error {}
        api.listProfilesError = Offline()
        let before = c.needsPairing
        await c.resolveMappings()
        XCTAssertEqual(c.needsPairing, before, "a network blip must never flip an app-modal gate true")
        XCTAssertEqual(announcements, 1, "every pass announces, the bail-outs included")
    }

    func testActionableSeparatesOutTheUndecryptableRemote() async throws {
        let api = FakeAPI()
        let provider = FakeDeviceKeyProvider()
        let mgr = AccountKeyManager(api: api, deviceKeyProvider: provider)
        _ = try await mgr.bootstrap()
        api.profileEnvelopes["stranger"] = Data([0x00, 0x01])
        let (c, _) = makeController(api: api, provider: provider, localsProvider: { [] })
        await c.silentUnlockAndResolve()
        XCTAssertTrue(c.needsPairing)
        XCTAssertTrue(c.needsPairingActionable)

        c.noteUndecryptableRemote("stranger")
        await c.resolveMappings()
        XCTAssertTrue(c.needsPairing)
        XCTAssertFalse(c.needsPairingActionable)

        c.noteDecryptableRemote("stranger")
        await c.resolveMappings()
        XCTAssertTrue(c.needsPairingActionable)
    }

    // MARK: - I-1: a locked / signed-out controller stops serving keys

    /// A resolve populates the cache; a later pass whose unlock fails must
    /// empty it and ping so Chromium re-pulls nil and closes the gate.
    func testUnlockFailureClearsResolvedAndPings() async throws {
        let api = FakeAPI()
        let provider = FakeDeviceKeyProvider()
        _ = try await AccountKeyManager(api: api, deviceKeyProvider: provider).bootstrap()
        var pings = 0
        let (c, _) = makeController(api: api, provider: provider,
                                    locals: [("Default", "Default")],
                                    pinged: { pings += 1 })
        await c.silentUnlockAndResolve()
        XCTAssertFalse(c.resolved.isEmpty)
        XCTAssertEqual(pings, 1)

        api.deviceEnvelopeError = KeyAPIError.http(401, "")
        await c.silentUnlockAndResolve()

        XCTAssertTrue(c.resolved.isEmpty)
        XCTAssertNil(c.profileSyncInfo(forProfileId: "Default"))
        XCTAssertFalse(c.needsPairing)
        XCTAssertEqual(pings, 2, "dropping a populated cache must ping so the fork re-pulls")
    }
}

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
                                  notifyChromium: pinged, isPairingComplete: { true })
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

    /// Review A11: the account is torn down while a pass is parked inside the first
    /// registration's network call. The pass resumes — on whatever token `AuthManager` now
    /// holds — and used to carry on registering every remaining unmapped local Profile,
    /// sealed with the retired account's ARK. After `retire()` a resumed pass writes nothing
    /// more and caches nothing.
    func testARetiredControllerStopsRegisteringOnceItsParkedPassResumes() async throws {
        let api = FakeAPI()
        let provider = FakeDeviceKeyProvider()
        _ = try await AccountKeyManager(api: api, deviceKeyProvider: provider).bootstrap()
        let store = MemoryMappingStore()
        let (c, _) = makeController(api: api, provider: provider,
                                    localsProvider: { [(profileId: "Default", displayName: "Default"),
                                                       (profileId: "Profile 1", displayName: "Work")] },
                                    store: store)
        // The account goes away while the first PUT is in flight.
        api.beforePutProfileKey = { await MainActor.run { c.retire() } }

        await c.silentUnlockAndResolve()

        XCTAssertLessThanOrEqual(api.profileEnvelopes.count, 1,
                                 "at most the request already in flight lands; nothing starts after retirement")
        XCTAssertTrue(c.resolved.isEmpty, "a retired controller caches nothing")
        XCTAssertFalse(c.needsPairing)
        XCTAssertTrue(c.isRetired)

        // And a later trigger on the same instance is a no-op too.
        await c.silentUnlockAndResolve()
        XCTAssertLessThanOrEqual(api.profileEnvelopes.count, 1)
    }

    /// D20: one unmapped local beside one unclaimed account Profile is not a match.
    /// The pass neither merges them nor registers the local while §3.6 can still
    /// claim that account Profile (the repair pass runs auto-create first).
    func testSingleRemoteSingleLocalAreNotMergedByCount() async throws {
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
        XCTAssertTrue(c.needsPairing)
        XCTAssertNil(c.profileSyncInfo(forProfileId: "Default"))
        XCTAssertEqual(api.profileEnvelopes.keys.sorted(), [recA.uuid], "no registration while the account Profile is claimable")
        XCTAssertEqual(c.knownUnmappedProfileIds, ["Default"])
        XCTAssertEqual(c.lastMappingsPassResult, .measured)
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
        var lastOutcome: SyncKeyController.MappingsOutcome?
        let token = NotificationCenter.default.addObserver(
            forName: .phiProfileMappingsDidResolve, object: nil, queue: nil) { note in
                announcements += 1
                lastOutcome = (note.userInfo?[SyncKeyController.mappingsOutcomeKey] as? String)
                    .flatMap(SyncKeyController.MappingsOutcome.init(rawValue:))
            }
        defer { NotificationCenter.default.removeObserver(token) }

        struct Offline: Error {}
        api.listProfilesError = Offline()
        let before = c.needsPairing
        await c.resolveMappings()
        XCTAssertEqual(c.needsPairing, before, "a network blip must never flip an app-modal gate true")
        XCTAssertEqual(announcements, 1, "every pass announces, the bail-outs included")
        XCTAssertEqual(lastOutcome, SyncKeyController.MappingsOutcome.held,
                       "and it announces as HELD: those predicates were not measured, so no consumer "
                       + "may read them as an answer and retire a pending join")
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

    /// A resolve populates the cache; this device's envelope then disappears
    /// (remote revocation, server reset). A 404 is definitive even with the ARK
    /// held: the later pass must empty the cache and ping so Chromium re-pulls
    /// nil and closes the gate.
    func testNeedsJoinWithTheAccountKeyHeldClearsResolvedAndPings() async throws {
        let api = FakeAPI()
        let provider = FakeDeviceKeyProvider()
        _ = try await AccountKeyManager(api: api, deviceKeyProvider: provider).bootstrap()
        var pings = 0
        let (c, mgr) = makeController(api: api, provider: provider,
                                      locals: [("Default", "Default")],
                                      pinged: { pings += 1 })
        await c.silentUnlockAndResolve()
        XCTAssertFalse(c.resolved.isEmpty)
        XCTAssertNotNil(mgr.currentARK)
        XCTAssertEqual(pings, 1)

        let deviceKeyId = try provider.deviceKeyId()
        api.envelopes.removeValue(forKey: deviceKeyId)
        await c.silentUnlockAndResolve()

        XCTAssertTrue(c.resolved.isEmpty)
        XCTAssertNil(c.profileSyncInfo(forProfileId: "Default"))
        XCTAssertFalse(c.needsPairing)
        XCTAssertEqual(pings, 2, "dropping a populated cache must ping so the fork re-pulls")
    }

    /// Without the ARK the unknown state still fails closed: a populated cache is
    /// dropped on a thrown unlock, and the first successful unlock's
    /// `.phiAccountKeyDidUnlock` is what retries.
    func testUnlockFailureWithoutTheAccountKeyClearsResolvedAndPings() async throws {
        let api = FakeAPI()
        let provider = FakeDeviceKeyProvider()
        _ = try await AccountKeyManager(api: api, deviceKeyProvider: provider).bootstrap()
        var pings = 0
        let (c, mgr) = makeController(api: api, provider: provider,
                                      locals: [("Default", "Default")],
                                      pinged: { pings += 1 })
        await c.silentUnlockAndResolve()
        XCTAssertFalse(c.resolved.isEmpty)
        XCTAssertEqual(pings, 1)

        mgr.discardARK()
        api.deviceEnvelopeError = KeyAPIError.transport(URLError(.notConnectedToInternet))
        await c.silentUnlockAndResolve()

        XCTAssertTrue(c.resolved.isEmpty)
        XCTAssertNil(c.profileSyncInfo(forProfileId: "Default"))
        XCTAssertEqual(pings, 2)
    }

    /// BH-52: with the ARK held nothing would retry a cleared cache (the unlock
    /// notification fires only on nil -> unlocked), so a transient unlock failure
    /// keeps the keys and still runs a mapping pass.
    func testTransientUnlockFailureWithTheAccountKeyHeldKeepsResolvedAndStillResolves() async throws {
        let api = FakeAPI()
        let provider = FakeDeviceKeyProvider()
        _ = try await AccountKeyManager(api: api, deviceKeyProvider: provider).bootstrap()
        var pings = 0
        var locals = [(profileId: "Default", displayName: "Default")]
        let (c, mgr) = makeController(api: api, provider: provider,
                                      localsProvider: { locals },
                                      pinged: { pings += 1 })
        await c.silentUnlockAndResolve()
        let before = try XCTUnwrap(c.profileSyncInfo(forProfileId: "Default"))
        XCTAssertNotNil(mgr.currentARK)
        XCTAssertEqual(pings, 1)
        var outcomes: [SyncKeyController.MappingsOutcome] = []
        let token = NotificationCenter.default.addObserver(
            forName: .phiProfileMappingsDidResolve, object: c, queue: nil) { note in
                if let outcome = (note.userInfo?[SyncKeyController.mappingsOutcomeKey] as? String)
                    .flatMap(SyncKeyController.MappingsOutcome.init(rawValue:)) {
                    outcomes.append(outcome)
                }
            }
        defer { NotificationCenter.default.removeObserver(token) }

        locals.append((profileId: "Profile 1", displayName: "Work"))
        api.deviceEnvelopeError = KeyAPIError.transport(URLError(.timedOut))
        await c.silentUnlockAndResolve()

        XCTAssertFalse(outcomes.contains(.cleared), "a transient failure with the ARK held must not clear")
        let after = try XCTUnwrap(c.profileSyncInfo(forProfileId: "Default"))
        XCTAssertEqual(after.uuid, before.uuid)
        XCTAssertEqual(after.passphrase, before.passphrase)
        XCTAssertNotNil(c.profileSyncInfo(forProfileId: "Profile 1"), "the mapping pass still ran")
        XCTAssertEqual(c.resolved.count, 2)
        XCTAssertEqual(pings, 2, "one ping from the pass, none from a clear")
    }

    /// A 401 on a live controller with the ARK held is a token blip, not a
    /// sign-out (sign-out retires the controller): the keys stay.
    func testNotSignedInWithTheAccountKeyHeldKeepsResolved() async throws {
        let api = FakeAPI()
        let provider = FakeDeviceKeyProvider()
        _ = try await AccountKeyManager(api: api, deviceKeyProvider: provider).bootstrap()
        var pings = 0
        let (c, _) = makeController(api: api, provider: provider,
                                    locals: [("Default", "Default")],
                                    pinged: { pings += 1 })
        await c.silentUnlockAndResolve()
        let before = try XCTUnwrap(c.profileSyncInfo(forProfileId: "Default"))

        api.deviceEnvelopeError = KeyAPIError.http(401, "")
        await c.silentUnlockAndResolve()

        XCTAssertEqual(c.profileSyncInfo(forProfileId: "Default")?.uuid, before.uuid)
        XCTAssertEqual(c.resolved.count, 1)
        XCTAssertEqual(pings, 2, "one ping from the pass, none from a clear")
    }

    /// BH-52: the startup unlock and the Profile-list follow-up overlap. Unlock
    /// passes are single-flight: callers that arrive while one is parked in the
    /// device-envelope lookup coalesce into one follow-up pass, and every caller
    /// returns only after it.
    func testOverlappingSilentUnlocksRunOnePassAndOneFollowUp() async throws {
        let api = FakeAPI()
        let provider = FakeDeviceKeyProvider()
        _ = try await AccountKeyManager(api: api, deviceKeyProvider: provider).bootstrap()
        let (c, _) = makeController(api: api, provider: provider, locals: [("Default", "Default")])
        let callsBefore = api.getDeviceEnvelopeCalls
        var enteredContinuation: AsyncStream<Void>.Continuation?
        let entered = AsyncStream<Void> { enteredContinuation = $0 }
        var releaseContinuation: AsyncStream<Void>.Continuation?
        let release = AsyncStream<Void> { releaseContinuation = $0 }
        let enteredSignal = try XCTUnwrap(enteredContinuation)
        let releaseSignal = try XCTUnwrap(releaseContinuation)
        api.beforeGetDeviceEnvelopeOnce = {
            enteredSignal.yield()
            for await _ in release { break }
        }

        async let first: Void = c.silentUnlockAndResolve()
        for await _ in entered { break }          // the first pass is parked inside the lookup
        async let second: Void = c.silentUnlockAndResolve()
        async let third: Void = c.silentUnlockAndResolve()
        for _ in 0..<10 { await Task.yield() }    // let both callers arrive while it is parked
        releaseSignal.yield()
        _ = await (first, second, third)

        XCTAssertLessThanOrEqual(api.getDeviceEnvelopeCalls - callsBefore, 2,
                                 "one pass plus one coalesced follow-up")
        XCTAssertEqual(api.maxGetDeviceEnvelopeInFlight, 1, "unlock passes never interleave")
        XCTAssertEqual(c.resolved.count, 1)
        XCTAssertNotNil(c.profileSyncInfo(forProfileId: "Default"))
        XCTAssertEqual(api.profileEnvelopes.count, 1)
    }

    /// T17 run 4 (2026-09-11): the login unlock and the `$profiles` sink each
    /// drove a pass, the two interleaved at their awaits, and BOTH registered
    /// "Default" -- two account profiles named "Your Phi", one of them later
    /// auto-created back as "Your Phi (2)". Passes are single-flight now: a
    /// caller that arrives mid-pass gets exactly one follow-up pass, never a
    /// concurrent one.
    func testConcurrentPassesRegisterALocalOnce() async throws {
        let api = FakeAPI()
        let provider = FakeDeviceKeyProvider()
        _ = try await AccountKeyManager(api: api, deviceKeyProvider: provider).bootstrap()
        let store = MemoryMappingStore()
        let (c, mgr) = makeController(api: api, provider: provider,
                                      localsProvider: { [(profileId: "Default", displayName: "Your Phi")] },
                                      store: store)
        _ = try await mgr.unlockAtStartup()
        // Suspend inside the registration so the second pass can start before
        // the first has written its mapping -- the exact interleaving seen live.
        api.beforePutProfileKey = { await Task.yield(); await Task.yield() }

        async let first: Void = c.resolveMappings()
        async let second: Void = c.resolveMappings()
        _ = await (first, second)

        XCTAssertEqual(api.profileEnvelopes.count, 1, "one local profile, one account profile")
        XCTAssertEqual(c.resolved.count, 1)
        XCTAssertEqual(store.globalUuid(forProfileId: "Default"), api.profileEnvelopes.keys.first)
        XCTAssertFalse(c.needsPairing)
    }

    /// The coalescing must not swallow a caller's own state change: a pass that
    /// starts while another is running re-reads the locals after the first
    /// finishes, so a profile that appeared mid-pass is registered by the
    /// follow-up pass rather than waiting for the next trigger.
    func testACallerArrivingMidPassGetsAFollowUpPass() async throws {
        let api = FakeAPI()
        let provider = FakeDeviceKeyProvider()
        _ = try await AccountKeyManager(api: api, deviceKeyProvider: provider).bootstrap()
        var locals = [(profileId: "Default", displayName: "Your Phi")]
        let (c, mgr) = makeController(api: api, provider: provider, localsProvider: { locals })
        _ = try await mgr.unlockAtStartup()
        api.beforePutProfileKey = { await Task.yield(); await Task.yield() }

        async let first: Void = c.resolveMappings()
        locals.append((profileId: "Profile 1", displayName: "Work"))
        async let second: Void = c.resolveMappings()
        _ = await (first, second)

        XCTAssertEqual(c.resolved.count, 2, "the follow-up pass saw the profile added mid-pass")
        XCTAssertEqual(api.profileEnvelopes.count, 2)
    }

    // MARK: - R4: the registration wait follows the account's Profile entities

    private func controllerWithRemote(view: @escaping @MainActor () -> AccountProfileEntityView?)
    async throws -> (SyncKeyController, FakeAPI, String) {
        let api = FakeAPI()
        let provider = FakeDeviceKeyProvider()
        let mgr = AccountKeyManager(api: api, deviceKeyProvider: provider)
        _ = try await mgr.bootstrap()
        let store = MemoryMappingStore()
        let pkm = ProfileKeyManager(api: api, keyManager: mgr, mappingStore: store)
        let other = try await pkm.registerLocalProfile(profileId: "temp", displayName: "Work")
        store.removeMapping(forProfileId: "temp")
        let controller = SyncKeyController(
            manager: mgr, approvals: DeviceApprovalService(api: api, keyManager: mgr, deviceKeyProvider: provider),
            profileKeys: pkm, localProfilesProvider: { [(profileId: "Default", displayName: "Default")] },
            notifyChromium: {}, isPairingComplete: { true }, profileEntityView: view)
        return (controller, api, other.uuid)
    }

    /// F2: a deleted account Profile's registry row stays forever. It must neither hold this
    /// Mac's registration nor keep `needsPairing` true.
    func testADeletedAccountProfileHoldsNeitherRegistrationNorPairing() async throws {
        let (c, api, _) = try await controllerWithRemote(view: {
            AccountProfileEntityView(liveNames: [:], deletedUuids: [])
        })
        await c.silentUnlockAndResolve()
        XCTAssertNotNil(c.profileSyncInfo(forProfileId: "Default"), "registered as a new account Profile")
        XCTAssertEqual(api.profileEnvelopes.count, 2)
        XCTAssertFalse(c.needsPairing)
    }

    func testALiveAccountProfileStillHoldsRegistration() async throws {
        var liveUuid = ""
        let (c, api, uuid) = try await controllerWithRemote(view: {
            AccountProfileEntityView(liveNames: [liveUuid: "Work"], deletedUuids: [])
        })
        liveUuid = uuid
        await c.silentUnlockAndResolve()
        XCTAssertNil(c.profileSyncInfo(forProfileId: "Default"), "auto-create may still claim it")
        XCTAssertEqual(api.profileEnvelopes.count, 1)
        XCTAssertTrue(c.needsPairing)
    }

    /// Before the first full replay auto-create claims nothing, so nothing may wait on it: the
    /// pause that wait causes would keep the replay from running.
    func testBeforeTheFirstReplayNothingIsClaimable() async throws {
        let (c, api, _) = try await controllerWithRemote(view: { nil })
        await c.silentUnlockAndResolve()
        XCTAssertNotNil(c.profileSyncInfo(forProfileId: "Default"))
        XCTAssertEqual(api.profileEnvelopes.count, 2)
    }

    // MARK: - Per-Profile key withdrawal (Profile deletion)

    func testAWithdrawnProfileKeepsNoKeyAndIsNeverUnmapped() async throws {
        let api = FakeAPI()
        let provider = FakeDeviceKeyProvider()
        _ = try await AccountKeyManager(api: api, deviceKeyProvider: provider).bootstrap()
        var pings = 0
        let (c, _) = makeController(api: api, provider: provider,
                                    locals: [("Default", "Default"), ("Profile 1", "Work")],
                                    pinged: { pings += 1 })
        await c.silentUnlockAndResolve()
        XCTAssertNotNil(c.profileSyncInfo(forProfileId: "Profile 1"))
        let pingsBefore = pings

        c.withdrawProfileKey(profileId: "Profile 1")
        XCTAssertNil(c.profileSyncInfo(forProfileId: "Profile 1"))
        XCTAssertGreaterThan(pings, pingsBefore, "Chromium re-pulls and stops that Profile's sync")

        await c.resolveMappings()
        XCTAssertNil(c.profileSyncInfo(forProfileId: "Profile 1"), "a pass does not hand the key back")
        XCTAssertFalse(c.knownUnmappedProfileIds.contains("Profile 1"))
        XCTAssertFalse(c.needsPairing)

        c.restoreProfileKey(profileId: "Profile 1")
        await c.resolveMappings()
        XCTAssertNotNil(c.profileSyncInfo(forProfileId: "Profile 1"), "a failed deletion gives it back")
    }
}

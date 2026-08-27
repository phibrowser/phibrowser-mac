import XCTest
import CryptoKit
@testable import Phi

@MainActor
final class SyncKeyControllerTests: XCTestCase {
    typealias FakeAPI = AccountKeyManagerTests.FakeAPI
    typealias FakeDeviceKeyProvider = AccountKeyManagerTests.FakeDeviceKeyProvider
    typealias MemoryMappingStore = ProfileKeyManagerTests.MemoryMappingStore

    private func makeController(api: FakeAPI, provider: FakeDeviceKeyProvider,
                                locals: [(String, String)],
                                pinged: @escaping () -> Void = {}) -> (SyncKeyController, AccountKeyManager) {
        let mgr = AccountKeyManager(api: api, deviceKeyProvider: provider)
        let pkm = ProfileKeyManager(api: api, keyManager: mgr, mappingStore: MemoryMappingStore())
        let approvals = DeviceApprovalService(api: api, keyManager: mgr, deviceKeyProvider: provider)
        let c = SyncKeyController(manager: mgr, approvals: approvals, profileKeys: pkm,
                                  localProfilesProvider: { locals.map { (profileId: $0.0, displayName: $0.1) } },
                                  notifyChromium: pinged)
        return (c, mgr)
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
}

import XCTest
import CryptoKit
@testable import Phi

final class ProfileKeyManagerTests: XCTestCase {
    typealias FakeAPI = AccountKeyManagerTests.FakeAPI
    typealias FakeDeviceKeyProvider = AccountKeyManagerTests.FakeDeviceKeyProvider

    final class MemoryMappingStore: ProfileSyncMappingStore {
        var map: [String: String] = [:]
        func globalUuid(forProfileId id: String) -> String? { map[id] }
        func setGlobalUuid(_ uuid: String, forProfileId id: String) { map[id] = uuid }
        func allMappings() -> [String: String] { map }
        func removeMapping(forProfileId id: String) { map.removeValue(forKey: id) }
        func removeAllMappings() { map = [:] }
    }

    private func unlockedStack() async throws -> (FakeAPI, AccountKeyManager, ProfileKeyManager, MemoryMappingStore) {
        let api = FakeAPI()
        let mgr = AccountKeyManager(api: api, deviceKeyProvider: FakeDeviceKeyProvider())
        _ = try await mgr.bootstrap()
        let store = MemoryMappingStore()
        return (api, mgr, ProfileKeyManager(api: api, keyManager: mgr, mappingStore: store), store)
    }

    func testRegisterWhenLockedThrows() async throws {
        let api = FakeAPI()
        let locked = AccountKeyManager(api: api, deviceKeyProvider: FakeDeviceKeyProvider()) // currentARK nil
        let pkm = ProfileKeyManager(api: api, keyManager: locked, mappingStore: MemoryMappingStore())
        do { _ = try await pkm.registerLocalProfile(profileId: "Default", displayName: "Default"); XCTFail() }
        catch ProfileKeyManagerError.notUnlocked {}
    }

    func testRegisterRoundTrip() async throws {
        let (api, mgr, pkm, store) = try await unlockedStack()
        let rec = try await pkm.registerLocalProfile(profileId: "Default", displayName: "Work")
        XCTAssertEqual(rec.passphrase.count, 64)
        XCTAssertEqual(store.map["Default"], rec.uuid)
        // Envelope round-trips through the ARK and carries the display name.
        let env = api.profileEnvelopes[rec.uuid]!
        let opened = try PhiKeyCrypto.openWithSymmetric(env, key: mgr.currentARK!)
        let json = try JSONSerialization.jsonObject(with: opened) as! [String: Any]
        XCTAssertEqual(json["v"] as? Int, 1)
        XCTAssertEqual(json["name"] as? String, "Work")
        let keyBytes = Data(base64Encoded: json["key"] as! String)!
        XCTAssertEqual(ProfileKeyManager.passphrase(fromKey: keyBytes), rec.passphrase)
    }

    func testRegisterConflictAdoptsWinner() async throws {
        let (api, mgr, pkm, _) = try await unlockedStack()
        // Pre-seed the winner's envelope under the uuid the loser will try.
        let winnerKey = Data((0..<32).map { UInt8($0) })
        let payload = try JSONSerialization.data(withJSONObject: ["v": 1, "key": winnerKey.base64EncodedString(), "name": "W"])
        let uuid = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
        api.profileEnvelopes[uuid] = try PhiKeyCrypto.sealWithSymmetric(payload, key: mgr.currentARK!)
        let rec = try await pkm.adoptRemoteProfile(uuid: uuid, forLocalProfile: "Default")
        XCTAssertEqual(rec.passphrase, ProfileKeyManager.passphrase(fromKey: winnerKey))
        XCTAssertEqual(rec.name, "W")
    }

    func testResolvedRecordUsesMapping() async throws {
        let (_, _, pkm, store) = try await unlockedStack()
        let rec = try await pkm.registerLocalProfile(profileId: "Profile 1", displayName: "Home")
        XCTAssertEqual(store.map["Profile 1"], rec.uuid)
        let resolved = try await pkm.resolvedRecord(forLocalProfile: "Profile 1")
        XCTAssertEqual(resolved, rec)
        let unmapped = try await pkm.resolvedRecord(forLocalProfile: "Profile 2")
        XCTAssertNil(unmapped)
    }

    /// C-1 defence in depth: whatever a caller believes about the mapping
    /// state, minting a second global UUID for an already-mapped local profile
    /// is refused outright — that is the step that would orphan the account's
    /// real envelope and diverge the devices for good.
    func testRegisterOnAlreadyMappedProfileThrows() async throws {
        let (api, _, pkm, store) = try await unlockedStack()
        let first = try await pkm.registerLocalProfile(profileId: "Default", displayName: "Work")
        XCTAssertEqual(api.profileEnvelopes.count, 1)
        do {
            _ = try await pkm.registerLocalProfile(profileId: "Default", displayName: "Work")
            XCTFail("expected alreadyMapped")
        } catch ProfileKeyManagerError.alreadyMapped {}
        XCTAssertEqual(store.map["Default"], first.uuid, "mapping must survive the refusal")
        XCTAssertEqual(api.profileEnvelopes.count, 1, "no second envelope may be minted")
    }

    func testAccountProfilesDecryptsNames() async throws {
        let (_, _, pkm, _) = try await unlockedStack()
        _ = try await pkm.registerLocalProfile(profileId: "Default", displayName: "Work")
        let remotes = try await pkm.accountProfiles()
        XCTAssertEqual(remotes.count, 1)
        XCTAssertEqual(remotes[0].name, "Work")
    }

    func testReverseLookupFindsTheLocalProfileForAGlobalUuid() async throws {
        let (_, _, pkm, store) = try await unlockedStack()
        store.map = ["Default": "uuid-a", "Profile 1": "uuid-b"]
        XCTAssertEqual(pkm.localProfileId(forGlobalUuid: "uuid-b"), "Profile 1")
        XCTAssertNil(pkm.localProfileId(forGlobalUuid: "uuid-z"))
    }

    /// Two locals on one uuid is a state M2 does not intend to produce, but the
    /// resolution has to be identical on every device or two machines land the
    /// same Space on different profiles.
    func testReverseLookupBreaksDuplicateMappingsDeterministically() async throws {
        let (_, _, pkm, store) = try await unlockedStack()
        store.map = ["Profile 9": "uuid-a", "Profile 2": "uuid-a"]
        XCTAssertEqual(pkm.localProfileId(forGlobalUuid: "uuid-a"), "Profile 2")
    }

    func testAccountProfileUuidsSendsOneListAndNoEnvelopeFetches() async throws {
        let (api, _, pkm, _) = try await unlockedStack()
        _ = try await pkm.registerLocalProfile(profileId: "Default", displayName: "Work")
        _ = try await pkm.registerLocalProfile(profileId: "Profile 1", displayName: "Home")
        let before = api.getProfileKeyCalls
        let uuids = try await pkm.accountProfileUuids()
        XCTAssertEqual(uuids.count, 2)
        XCTAssertEqual(api.getProfileKeyCalls, before, "accountProfileUuids must not pay 1+N")
    }

    func testAccountProfileUuidsThrowsWhenLockedWithoutAnyNetworkCall() async throws {
        let api = FakeAPI()
        let locked = AccountKeyManager(api: api, deviceKeyProvider: FakeDeviceKeyProvider())
        let pkm = ProfileKeyManager(api: api, keyManager: locked, mappingStore: MemoryMappingStore())
        do {
            _ = try await pkm.accountProfileUuids()
            XCTFail("expected notUnlocked")
        } catch ProfileKeyManagerError.notUnlocked {
            XCTAssertEqual(api.listProfilesCalls, 0, "the ARK guard must precede the request")
        }
    }

    func testRemoteProfileDecryptsTheRegisteredNameAndReportsUndecryptable() async throws {
        let (api, _, pkm, _) = try await unlockedStack()
        let rec = try await pkm.registerLocalProfile(profileId: "Default", displayName: "Work")
        let mine = try await pkm.remoteProfile(uuid: rec.uuid)
        XCTAssertEqual(mine.name, "Work")

        api.profileEnvelopes["garbage-uuid"] = Data([0x00, 0x01, 0x02])
        let broken = try await pkm.remoteProfile(uuid: "garbage-uuid")
        XCTAssertEqual(broken.uuid, "garbage-uuid")
        XCTAssertNil(broken.name)
    }

    func testRemoveMappingDropsOnlyThatEntry() async throws {
        let (_, _, _, store) = try await unlockedStack()
        store.map = ["Default": "uuid-a", "Profile 1": "uuid-b"]
        store.removeMapping(forProfileId: "Default")
        XCTAssertEqual(store.map, ["Profile 1": "uuid-b"])
        store.removeAllMappings()
        XCTAssertTrue(store.map.isEmpty)
    }

    // MARK: - Concurrent envelope fetches (task 20)

    /// A `KeyEnvelopeAPI` whose PROFILE endpoints are safe to drive from several
    /// tasks at once. `accountProfiles()` fetches its envelopes concurrently
    /// now, and `FakeAPI` synchronises nothing — its `getProfileKeyCalls += 1`
    /// and its `profileEnvelopes` lookup would be a genuine data race under a
    /// task group. The account/device/join endpoints keep forwarding to a plain
    /// `FakeAPI`: they are only ever driven serially, by `bootstrap()`, before
    /// any of this concurrency starts.
    final class ConcurrentProfileAPI: KeyEnvelopeAPI {
        let inner = FakeAPI()

        private let lock = NSLock()
        private var envelopes: [String: Data] = [:]
        private var failingUuids: Set<String> = []
        private var _getProfileKeyCalls = 0

        /// Registers an envelope under `uuid`; the listing is its sorted key set.
        func seed(uuid: String, envelope: Data) {
            withLock { $0.envelopes[uuid] = envelope }
        }

        /// Makes this uuid's envelope GET fail on the wire (not a decode failure).
        func failEnvelope(uuid: String) {
            withLock { _ = $0.failingUuids.insert(uuid) }
        }

        var getProfileKeyCalls: Int { withLock { $0._getProfileKeyCalls } }

        /// Every critical section goes through here, and every caller of it is
        /// SYNCHRONOUS: `NSLock.lock()` is unavailable from an async context, so
        /// the async endpoints below take their snapshot in one of these first.
        private func withLock<T>(_ body: (ConcurrentProfileAPI) -> T) -> T {
            lock.lock(); defer { lock.unlock() }; return body(self)
        }

        private func listedUuids() -> [String] { withLock { $0.envelopes.keys.sorted() } }

        private func envelopeLookup(uuid: String) -> (shouldFail: Bool, envelope: Data?) {
            withLock {
                $0._getProfileKeyCalls += 1
                return ($0.failingUuids.contains(uuid), $0.envelopes[uuid])
            }
        }

        private func storeEnvelope(uuid: String, envelope: Data) -> Bool {
            withLock {
                if $0.envelopes[uuid] != nil { return false }
                $0.envelopes[uuid] = envelope
                return true
            }
        }

        func listProfiles() async throws -> [ProfileSummaryDTO] {
            listedUuids().map {
                ProfileSummaryDTO(profileUuid: $0, hasEnvelope: true, createdAt: FakeAPI.profileCreatedAt)
            }
        }

        func getProfileKey(uuid: String) async throws -> ProfileKeyDTO? {
            let (shouldFail, envelope) = envelopeLookup(uuid: uuid)
            if shouldFail { throw KeyAPIError.http(503, "") }
            guard let envelope else { return nil }
            return ProfileKeyDTO(profileUuid: uuid, profileKeyEnvelope: envelope,
                                 createdAt: FakeAPI.profileCreatedAt)
        }

        func putProfileKey(uuid: String, envelope: Data) async throws -> Bool {
            storeEnvelope(uuid: uuid, envelope: envelope)
        }

        // Serial-only endpoints: straight through to the shared fake.
        func putAccount(salt: Data, kdfVersion: String, kdfParams: Data, recoveryEnvelope: Data) async throws -> Bool {
            try await inner.putAccount(salt: salt, kdfVersion: kdfVersion,
                                       kdfParams: kdfParams, recoveryEnvelope: recoveryEnvelope)
        }
        func getAccount() async throws -> AccountKeyStateDTO? { try await inner.getAccount() }
        func postDevice(deviceKeyId: String, publicKey: Data, name: String, platform: String, arkEnvelope: Data?) async throws {
            try await inner.postDevice(deviceKeyId: deviceKeyId, publicKey: publicKey,
                                       name: name, platform: platform, arkEnvelope: arkEnvelope)
        }
        func getDeviceEnvelope(deviceKeyId: String) async throws -> Data? {
            try await inner.getDeviceEnvelope(deviceKeyId: deviceKeyId)
        }
        func revokeDevice(deviceKeyId: String) async throws {
            try await inner.revokeDevice(deviceKeyId: deviceKeyId)
        }
        func postJoinRequest(publicKey: Data, name: String, platform: String) async throws -> String {
            try await inner.postJoinRequest(publicKey: publicKey, name: name, platform: platform)
        }
        func listPendingJoinRequests() async throws -> [JoinRequestSummaryDTO] {
            try await inner.listPendingJoinRequests()
        }
        func getJoinRequest(id: String) async throws -> JoinRequestDTO {
            try await inner.getJoinRequest(id: id)
        }
        func approveJoinRequest(id: String, grantedArkEnvelope: Data, resolvedByDeviceKeyId: String) async throws {
            try await inner.approveJoinRequest(id: id, grantedArkEnvelope: grantedArkEnvelope,
                                               resolvedByDeviceKeyId: resolvedByDeviceKeyId)
        }
        func denyJoinRequest(id: String) async throws { try await inner.denyJoinRequest(id: id) }
        func getDomainKey(domain: String) async throws -> Data? { try await inner.getDomainKey(domain: domain) }
        func putDomainKey(domain: String, envelope: Data) async throws -> Bool {
            try await inner.putDomainKey(domain: domain, envelope: envelope)
        }
    }

    private func concurrentStack() async throws -> (ConcurrentProfileAPI, AccountKeyManager, ProfileKeyManager) {
        let api = ConcurrentProfileAPI()
        let mgr = AccountKeyManager(api: api, deviceKeyProvider: FakeDeviceKeyProvider())
        _ = try await mgr.bootstrap()
        return (api, mgr, ProfileKeyManager(api: api, keyManager: mgr, mappingStore: MemoryMappingStore()))
    }

    /// The envelope GETs run concurrently now — five strictly serial round trips
    /// on a session with a 60 s timeout was minutes of spinner in front of a
    /// freshly joined device — so the order of the returned array can no longer
    /// come from the order the answers happen to arrive in. It must still be the
    /// listing's order, and an envelope that will not open must still occupy its
    /// row with `name == nil` rather than throwing or being dropped.
    func testAccountProfilesKeepsTheListingOrderWhenFetchedConcurrently() async throws {
        let (api, mgr, pkm) = try await concurrentStack()
        let ark = mgr.currentARK!
        for (uuid, name) in [("uuid-a", "A"), ("uuid-b", "B"), ("uuid-c", "C"), ("uuid-d", "D")] {
            api.seed(uuid: uuid, envelope: try ProfileKeyManager.sealProfilePayload(
                key: Data(repeating: 0x11, count: 32), name: name, ark: ark))
        }
        api.seed(uuid: "uuid-e", envelope: Data([0x00, 0x01, 0x02]))   // opens under no ARK

        let remotes = try await pkm.accountProfiles()
        XCTAssertEqual(remotes.map(\.uuid), ["uuid-a", "uuid-b", "uuid-c", "uuid-d", "uuid-e"])
        XCTAssertEqual(remotes.map(\.name), ["A", "B", "C", "D", nil])
        XCTAssertEqual(api.getProfileKeyCalls, 5, "one envelope GET per listed profile, no more")
    }

    /// A transport failure on ONE envelope still fails the whole call, exactly as
    /// the serial loop did. Nothing here asserts on how many requests a mid-list
    /// failure produces: that is the one thing concurrency really changes (the
    /// group has already issued them all), and no shipped behaviour depends on it.
    func testAccountProfilesStillThrowsWhenOneEnvelopeFetchFails() async throws {
        let (api, mgr, pkm) = try await concurrentStack()
        let ark = mgr.currentARK!
        api.seed(uuid: "uuid-a", envelope: try ProfileKeyManager.sealProfilePayload(
            key: Data(repeating: 0x11, count: 32), name: "A", ark: ark))
        api.seed(uuid: "uuid-b", envelope: Data([0x00]))
        api.failEnvelope(uuid: "uuid-b")

        do {
            _ = try await pkm.accountProfiles()
            XCTFail("a transport failure on one envelope must still fail the whole call")
        } catch {
            // The specific error is the transport's; only "it throws" is the contract.
        }
    }
}

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
}

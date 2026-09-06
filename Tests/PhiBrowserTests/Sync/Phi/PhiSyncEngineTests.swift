import CryptoKit
import XCTest
@testable import Phi

/// Drives one Commit/GetUpdates round through a fake protocol client. The fake mirrors the
/// sync-service semantics the engine depends on: entities are keyed by `client_tag_hash`,
/// entity ids are server-assigned, versions come from a global counter (never
/// `baseVersion + 1`), and a stale `baseVersion` yields CONFLICT.
final class PhiSyncEngineTests: XCTestCase {
    private var defaults: UserDefaults!
    private var defaultsSuiteName: String!
    private let settingKey = "theme.dark"

    override func setUp() {
        super.setUp()
        defaultsSuiteName = "PhiSyncEngineTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        defaults = nil
        defaultsSuiteName = nil
        super.tearDown()
    }

    // MARK: - Fakes

    /// Fixed domain key, standing in for `PhiDomainKeyManager`.
    final class StubDomainKeys: PhiDomainKeyProviding {
        let key: SymmetricKey
        var error: Error?
        private(set) var calls = 0
        init(key: SymmetricKey) { self.key = key }
        func domainKey() async throws -> SymmetricKey {
            calls += 1
            if let error { throw error }
            return key
        }
    }

    /// In-memory stand-in for `/chromium-sync/phi/command/`.
    final class FakePhiSyncClient: PhiSyncProtocolClient {
        struct Stored {
            var entityId: String
            var version: Int64
            var ciphertext: Data
            var deleted: Bool
        }
        struct CommitCall {
            let entityId: String?
            let clientTagHash: String
            let ciphertext: Data
            let baseVersion: Int64
            let storeBirthday: String
        }
        struct Page {
            let entities: [PhiRemoteEntity]
            let newMarker: Data
            let changesRemaining: Bool
        }

        /// Keyed by client tag hash, exactly like the server's unique index.
        private(set) var stored: [String: Stored] = [:]
        private(set) var getUpdatesCalls: [(marker: Data?, storeBirthday: String)] = []
        private(set) var commits: [CommitCall] = []

        var storeBirthday = "birthday-1"
        /// Global version sequence, like `nextval('entity_version_seq')`.
        var nextVersion: Int64 = 100
        var idCounter = 0
        /// Thrown by the next `getUpdates` call only, then cleared.
        var getUpdatesErrorOnce: Error?
        var commitErrorOnce: Error?
        /// Number of upcoming commits that report CONFLICT without touching the store.
        var forcedConflicts = 0
        /// When non-empty, `getUpdates` returns these pages in order instead of reading `stored`.
        var scriptedPages: [Page] = []

        func seed(ciphertext: Data, version: Int64, entityId: String = "srv-seed", deleted: Bool = false) {
            stored[PhiSyncEntity.clientTagHash] = Stored(entityId: entityId, version: version,
                                                         ciphertext: ciphertext, deleted: deleted)
        }

        func getUpdates(marker: Data?, storeBirthday: String) async throws
            -> (entities: [PhiRemoteEntity], newMarker: Data, storeBirthday: String, changesRemaining: Bool) {
            getUpdatesCalls.append((marker, storeBirthday))
            if let error = getUpdatesErrorOnce {
                getUpdatesErrorOnce = nil
                throw error
            }
            if !scriptedPages.isEmpty {
                let page = scriptedPages.removeFirst()
                return (page.entities, page.newMarker, self.storeBirthday, page.changesRemaining)
            }
            let from = Self.watermark(marker)
            let fresh = stored.compactMap { hash, row -> PhiRemoteEntity? in
                guard row.version > from else { return nil }
                return PhiRemoteEntity(entityId: row.entityId, clientTagHash: hash,
                                       version: row.version, ciphertext: row.ciphertext,
                                       deleted: row.deleted)
            }
            let highest = fresh.map(\.version).max()
            let newMarker = highest.map { Data(String($0).utf8) } ?? (marker ?? Data())
            return (fresh, newMarker, storeBirthday, false)
        }

        func commit(entityId: String?, clientTagHash: String, ciphertext: Data,
                    baseVersion: Int64, storeBirthday: String) async throws -> PhiCommitOutcome {
            commits.append(CommitCall(entityId: entityId, clientTagHash: clientTagHash,
                                      ciphertext: ciphertext, baseVersion: baseVersion,
                                      storeBirthday: storeBirthday))
            if let error = commitErrorOnce {
                commitErrorOnce = nil
                throw error
            }
            if forcedConflicts > 0 {
                forcedConflicts -= 1
                return .conflict(serverVersion: stored[clientTagHash]?.version)
            }
            nextVersion += 1
            if let entityId {
                // Update path: the row must exist and the base version must match.
                guard var row = stored[clientTagHash], row.entityId == entityId else {
                    throw PhiSyncProtocolError.commitRejected(.invalidMessage)
                }
                guard row.version == baseVersion else { return .conflict(serverVersion: row.version) }
                row.version = nextVersion
                row.ciphertext = ciphertext
                row.deleted = false
                stored[clientTagHash] = row
                return .applied(entityId: entityId, version: nextVersion, storeBirthday: self.storeBirthday)
            }
            // Create path: ON CONFLICT (client_tag_hash) DO UPDATE — it overwrites blindly,
            // which is exactly why the engine must pull before its first commit.
            let id = stored[clientTagHash]?.entityId ?? { idCounter += 1; return "srv-\(idCounter)" }()
            stored[clientTagHash] = Stored(entityId: id, version: nextVersion,
                                           ciphertext: ciphertext, deleted: false)
            return .applied(entityId: id, version: nextVersion, storeBirthday: self.storeBirthday)
        }

        private static func watermark(_ marker: Data?) -> Int64 {
            guard let marker, let text = String(data: marker, encoding: .utf8), let value = Int64(text) else { return 0 }
            return value
        }
    }

    // MARK: - Helpers

    /// One-element registry over the test's own key, per R3: the engine's unit tests must not
    /// depend on whatever `SyncableSettings.all` happens to contain.
    private func registry(_ key: String) -> [SyncableSetting] {
        [SyncableSetting(
            key: key,
            read: { defaults in
                var value = Phi_PhiSettingValue()
                value.boolValue = defaults.bool(forKey: key)
                return value
            },
            write: { value, defaults in
                if case .boolValue(let flag)? = value.v { defaults.set(flag, forKey: key) }
            })]
    }

    private func settingEntity(_ key: String, _ flag: Bool, at timestamp: Int64) -> Phi_PhiSettingEntity {
        var value = Phi_PhiSettingValue()
        value.updatedAtMs = timestamp
        value.boolValue = flag
        var entity = Phi_PhiSettingEntity()
        entity.values = [key: value]
        return entity
    }

    private func ciphertext(_ setting: Phi_PhiSettingEntity, key: SymmetricKey) throws -> Data {
        var wrapper = Phi_PhiEntity()
        wrapper.setting = setting
        return try PhiEntityCodec.encrypt(wrapper, key: key)
    }

    private func decryptSetting(_ ciphertext: Data, key: SymmetricKey) throws -> Phi_PhiSettingEntity {
        try PhiEntityCodec.decrypt(ciphertext, key: key).setting
    }

    private func makeEngine(_ client: FakePhiSyncClient,
                            key: SymmetricKey,
                            now: Int64) -> PhiSyncEngine {
        PhiSyncEngine(domainKeys: StubDomainKeys(key: key),
                      client: client,
                      defaults: defaults,
                      deviceKeyId: "devA",
                      settings: registry(settingKey),
                      now: { now })
    }

    // MARK: - Pull

    /// The brief's case: a remote value lands in local defaults. On a device that has never
    /// synced the remote entity is adopted wholesale (there is no local timestamp history to
    /// compare against), so the remote value wins regardless of its age.
    func testPullMergesRemoteSettingIntoDefaults() async throws {
        let key = SymmetricKey(size: .bits256)
        let client = FakePhiSyncClient()
        client.seed(ciphertext: try ciphertext(settingEntity(settingKey, true, at: 999), key: key), version: 5)

        let engine = makeEngine(client, key: key, now: 1_000)
        await engine.pullOnce()

        XCTAssertTrue(defaults.bool(forKey: settingKey))
        XCTAssertEqual(defaults.string(forKey: PhiSyncEngine.entityIdStateKey), "srv-seed")
        XCTAssertEqual(defaults.object(forKey: PhiSyncEngine.versionStateKey) as? NSNumber, NSNumber(value: Int64(5)))
        XCTAssertEqual(defaults.string(forKey: PhiSyncEngine.storeBirthdayStateKey), "birthday-1")
    }

    /// R5 echo suppression: applying a remote value must not look like a local edit, so the
    /// pull's trailing push finds nothing to publish and never calls commit.
    func testRemoteApplyProducesNoPush() async throws {
        let key = SymmetricKey(size: .bits256)
        let client = FakePhiSyncClient()
        client.seed(ciphertext: try ciphertext(settingEntity(settingKey, true, at: 999), key: key), version: 5)

        await makeEngine(client, key: key, now: 1_000).pullOnce()

        XCTAssertTrue(client.commits.isEmpty)
    }

    /// Once the device has synced once, a newer local edit survives a pull and is pushed back.
    func testPullKeepsTheNewerLocalValueAndPushesItBack() async throws {
        let key = SymmetricKey(size: .bits256)
        let client = FakePhiSyncClient()
        client.seed(ciphertext: try ciphertext(settingEntity(settingKey, false, at: 1_000), key: key), version: 5)

        // First sync: adopt false@1000.
        await makeEngine(client, key: key, now: 1_000).pullOnce()
        XCTAssertFalse(defaults.bool(forKey: settingKey))

        // The user flips the setting locally, then a later pull sees an older remote edit.
        defaults.set(true, forKey: settingKey)
        client.seed(ciphertext: try ciphertext(settingEntity(settingKey, false, at: 2_000), key: key), version: 6)
        await makeEngine(client, key: key, now: 3_000).pullOnce()

        XCTAssertTrue(defaults.bool(forKey: settingKey), "the newer local edit must win field-level LWW")
        XCTAssertEqual(client.commits.count, 1)
        let committed = try decryptSetting(client.commits[0].ciphertext, key: key)
        XCTAssertEqual(committed.values[settingKey]?.boolValue, true)
        XCTAssertEqual(committed.values[settingKey]?.updatedAtMs, 3_000)
    }

    /// A ciphertext this device cannot open must never be applied and must never be silently
    /// treated as "no remote value" — the cursor still advances so the next commit has a base.
    func testUndecryptableRemoteEntityLeavesLocalSettingsAlone() async throws {
        let key = SymmetricKey(size: .bits256)
        let client = FakePhiSyncClient()
        client.seed(ciphertext: try ciphertext(settingEntity(settingKey, true, at: 999), key: SymmetricKey(size: .bits256)),
                    version: 5)
        defaults.set(false, forKey: settingKey)

        await makeEngine(client, key: key, now: 1_000).pullOnce()

        XCTAssertFalse(defaults.bool(forKey: settingKey))
        XCTAssertEqual(defaults.string(forKey: PhiSyncEngine.entityIdStateKey), "srv-seed")
    }

    /// A tombstone must not be decrypted or applied, but its version is still the base for the
    /// next commit.
    func testDeletedRemoteEntityIsNotApplied() async throws {
        let key = SymmetricKey(size: .bits256)
        let client = FakePhiSyncClient()
        client.seed(ciphertext: Data(), version: 7, deleted: true)
        defaults.set(true, forKey: settingKey)

        await makeEngine(client, key: key, now: 1_000).pullOnce()

        XCTAssertTrue(defaults.bool(forKey: settingKey))
        XCTAssertEqual(defaults.object(forKey: PhiSyncEngine.versionStateKey) as? NSNumber, NSNumber(value: Int64(7)))
    }

    /// `changes_remaining > 0` means the server has more to hand over; the engine keeps asking
    /// with the marker it just received.
    func testPullDrainsPagesWhileChangesRemain() async throws {
        let key = SymmetricKey(size: .bits256)
        let client = FakePhiSyncClient()
        let entity = PhiRemoteEntity(entityId: "srv-1", clientTagHash: PhiSyncEntity.clientTagHash,
                                     version: 9,
                                     ciphertext: try ciphertext(settingEntity(settingKey, true, at: 999), key: key),
                                     deleted: false)
        client.scriptedPages = [
            FakePhiSyncClient.Page(entities: [], newMarker: Data("1".utf8), changesRemaining: true),
            FakePhiSyncClient.Page(entities: [entity], newMarker: Data("9".utf8), changesRemaining: false),
        ]

        await makeEngine(client, key: key, now: 1_000).pullOnce()

        XCTAssertEqual(client.getUpdatesCalls.count, 2)
        XCTAssertEqual(client.getUpdatesCalls[1].marker, Data("1".utf8))
        XCTAssertTrue(defaults.bool(forKey: settingKey))
    }

    /// NOT_MY_BIRTHDAY invalidates every persisted cursor; the engine drops them and re-pulls
    /// once from scratch (empty birthday, no marker).
    func testNotMyBirthdayClearsStateAndRePullsOnce() async throws {
        let key = SymmetricKey(size: .bits256)
        let client = FakePhiSyncClient()
        client.seed(ciphertext: try ciphertext(settingEntity(settingKey, true, at: 999), key: key), version: 5)
        defaults.set("stale-birthday", forKey: PhiSyncEngine.storeBirthdayStateKey)
        defaults.set(Data("4".utf8), forKey: PhiSyncEngine.markerStateKey)
        client.getUpdatesErrorOnce = PhiSyncProtocolError.notMyBirthday

        await makeEngine(client, key: key, now: 1_000).pullOnce()

        XCTAssertEqual(client.getUpdatesCalls.count, 2)
        XCTAssertEqual(client.getUpdatesCalls[0].storeBirthday, "stale-birthday")
        XCTAssertEqual(client.getUpdatesCalls[1].storeBirthday, "")
        XCTAssertNil(client.getUpdatesCalls[1].marker)
        XCTAssertTrue(defaults.bool(forKey: settingKey))
        XCTAssertEqual(defaults.string(forKey: PhiSyncEngine.storeBirthdayStateKey), "birthday-1")
    }

    // MARK: - Push

    /// The brief's push case: a local change is committed, and the ciphertext the client
    /// received decrypts back to that change.
    func testPushCommitsLocalChange() async throws {
        let key = SymmetricKey(size: .bits256)
        let client = FakePhiSyncClient()
        client.seed(ciphertext: try ciphertext(settingEntity(settingKey, false, at: 1_000), key: key), version: 5)
        await makeEngine(client, key: key, now: 1_000).pullOnce()

        defaults.set(true, forKey: settingKey)
        await makeEngine(client, key: key, now: 2_000).pushLocalSettings()

        XCTAssertEqual(client.commits.count, 1)
        XCTAssertEqual(client.commits[0].entityId, "srv-seed")
        XCTAssertEqual(client.commits[0].baseVersion, 5)
        XCTAssertEqual(client.commits[0].clientTagHash, PhiSyncEntity.clientTagHash)
        XCTAssertEqual(client.commits[0].storeBirthday, "birthday-1")
        let committed = try decryptSetting(client.commits[0].ciphertext, key: key)
        XCTAssertEqual(committed.values[settingKey]?.boolValue, true)
        XCTAssertEqual(committed.values[settingKey]?.updatedAtMs, 2_000)
        // The server-assigned id and the new version are persisted for the next round.
        XCTAssertEqual(defaults.object(forKey: PhiSyncEngine.versionStateKey) as? NSNumber, NSNumber(value: client.stored[PhiSyncEntity.clientTagHash]!.version))
    }

    /// R5: exactly one commit per local change, and none at all when nothing changed.
    func testLocalChangeProducesExactlyOneCommit() async throws {
        let key = SymmetricKey(size: .bits256)
        let client = FakePhiSyncClient()
        client.seed(ciphertext: try ciphertext(settingEntity(settingKey, false, at: 1_000), key: key), version: 5)
        let engine = makeEngine(client, key: key, now: 2_000)
        await engine.pullOnce()

        defaults.set(true, forKey: settingKey)
        await engine.handleLocalDefaultsChange()
        XCTAssertEqual(client.commits.count, 1)

        // A second notification with no further change must not commit again.
        await engine.handleLocalDefaultsChange()
        XCTAssertEqual(client.commits.count, 1)
    }

    /// A device that has never synced must discover the account's entity before committing;
    /// a blind `version = 0` create would overwrite it through the server's ON CONFLICT path.
    func testFirstPushPullsBeforeCommitting() async throws {
        let key = SymmetricKey(size: .bits256)
        let client = FakePhiSyncClient()
        client.seed(ciphertext: try ciphertext(settingEntity(settingKey, true, at: 999), key: key), version: 5)
        defaults.set(false, forKey: settingKey)

        await makeEngine(client, key: key, now: 1_000).pushLocalSettings()

        XCTAssertEqual(client.getUpdatesCalls.count, 1)
        XCTAssertTrue(client.commits.isEmpty, "the account's settings must be adopted, not clobbered")
        XCTAssertTrue(defaults.bool(forKey: settingKey))
    }

    /// If that discovery pull fails, the create must not go ahead on a guess — a blind
    /// `version = 0` commit would overwrite an entity this device simply could not read.
    func testFirstPushIsAbandonedWhenTheDiscoveryPullFails() async throws {
        let key = SymmetricKey(size: .bits256)
        let client = FakePhiSyncClient()
        client.getUpdatesErrorOnce = URLError(.notConnectedToInternet)
        defaults.set(true, forKey: settingKey)

        await makeEngine(client, key: key, now: 1_000).pushLocalSettings()

        XCTAssertEqual(client.getUpdatesCalls.count, 1)
        XCTAssertTrue(client.commits.isEmpty)
    }

    /// With nothing on the server, the first commit is a create: no entity id, base version 0.
    func testFirstCommitOnAnEmptyAccountIsACreate() async throws {
        let key = SymmetricKey(size: .bits256)
        let client = FakePhiSyncClient()
        defaults.set(true, forKey: settingKey)

        await makeEngine(client, key: key, now: 1_000).pushLocalSettings()

        XCTAssertEqual(client.commits.count, 1)
        XCTAssertNil(client.commits[0].entityId)
        XCTAssertEqual(client.commits[0].baseVersion, 0)
        XCTAssertEqual(defaults.string(forKey: PhiSyncEngine.entityIdStateKey), "srv-1")
    }

    /// CONFLICT drives exactly one pull-then-retry; it must not spin.
    func testCommitConflictPullsAndRetriesOnce() async throws {
        let key = SymmetricKey(size: .bits256)
        let client = FakePhiSyncClient()
        client.seed(ciphertext: try ciphertext(settingEntity(settingKey, false, at: 1_000), key: key), version: 5)
        let engine = makeEngine(client, key: key, now: 2_000)
        await engine.pullOnce()

        defaults.set(true, forKey: settingKey)
        client.forcedConflicts = 1
        await engine.pushLocalSettings()

        XCTAssertEqual(client.commits.count, 2, "one conflicted commit plus one retry")
        XCTAssertEqual(client.getUpdatesCalls.count, 2, "the conflict is resolved by pulling first")
    }

    /// A conflict that survives the retry is abandoned for this round rather than looping.
    func testRepeatedConflictStopsAfterOneRetry() async throws {
        let key = SymmetricKey(size: .bits256)
        let client = FakePhiSyncClient()
        client.seed(ciphertext: try ciphertext(settingEntity(settingKey, false, at: 1_000), key: key), version: 5)
        let engine = makeEngine(client, key: key, now: 2_000)
        await engine.pullOnce()

        defaults.set(true, forKey: settingKey)
        client.forcedConflicts = 5
        await engine.pushLocalSettings()

        XCTAssertEqual(client.commits.count, 2)
    }

    /// A locked key layer must abort the round quietly, without committing anything.
    func testLockedDomainKeyAbortsTheRound() async throws {
        let client = FakePhiSyncClient()
        let keys = StubDomainKeys(key: SymmetricKey(size: .bits256))
        keys.error = ProfileKeyManagerError.notUnlocked
        let engine = PhiSyncEngine(domainKeys: keys, client: client, defaults: defaults,
                                   deviceKeyId: "devA", settings: registry(settingKey), now: { 1_000 })

        await engine.pullOnce()
        await engine.pushLocalSettings()

        XCTAssertTrue(client.commits.isEmpty)
    }

    // MARK: - State

    /// Sign-out / account switch: every account-scoped cursor is dropped so account A's
    /// marker and version are never replayed against account B.
    func testResetSyncStateClearsEveryCursorKey() async throws {
        let key = SymmetricKey(size: .bits256)
        let client = FakePhiSyncClient()
        client.seed(ciphertext: try ciphertext(settingEntity(settingKey, true, at: 999), key: key), version: 5)
        let engine = makeEngine(client, key: key, now: 1_000)
        await engine.pullOnce()
        XCTAssertNotNil(defaults.string(forKey: PhiSyncEngine.entityIdStateKey))

        await engine.resetSyncState()

        for stateKey in PhiSyncEngine.stateKeys {
            XCTAssertNil(defaults.object(forKey: stateKey), "\(stateKey) survived the reset")
        }
    }
}

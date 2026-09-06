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

    /// A one-shot gate. `wait()` suspends until someone calls `open()`, which is how a test
    /// parks a round inside the fake network call and then lets it go.
    actor Gate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func open() {
            guard !isOpen else { return }
            isOpen = true
            for waiter in waiters { waiter.resume() }
            waiters.removeAll()
        }

        func wait() async {
            guard !isOpen else { return }
            await withCheckedContinuation { waiters.append($0) }
        }
    }

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
        /// Opened as soon as `getUpdates` is entered, so a test can wait for a round to be
        /// parked inside the network call.
        var arrivedInGetUpdates: Gate?
        /// Awaited inside `getUpdates`: while it is shut, the calling round is suspended.
        var getUpdatesGate: Gate?
        /// Ordered log of what the engine did on the wire, so a test can assert that a commit
        /// happened after a parked pull finished rather than during it.
        private(set) var callLog: [String] = []

        func seed(ciphertext: Data, version: Int64, entityId: String = "srv-seed", deleted: Bool = false) {
            stored[PhiSyncEntity.clientTagHash] = Stored(entityId: entityId, version: version,
                                                         ciphertext: ciphertext, deleted: deleted)
        }

        func getUpdates(marker: Data?, storeBirthday: String) async throws
            -> (entities: [PhiRemoteEntity], newMarker: Data, storeBirthday: String, changesRemaining: Bool) {
            getUpdatesCalls.append((marker, storeBirthday))
            callLog.append("getUpdates.begin")
            if let arrivedInGetUpdates { await arrivedInGetUpdates.open() }
            if let getUpdatesGate { await getUpdatesGate.wait() }
            defer { callLog.append("getUpdates.end") }
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
            callLog.append("commit")
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

    /// A ciphertext this device cannot open must never be applied — and, just as importantly,
    /// must never be published over: the trailing push would commit this device's snapshot
    /// against the id and version harvested from that very entity and replace the account's
    /// settings for every other device.
    func testUndecryptableRemoteEntityLeavesLocalSettingsAlone() async throws {
        let key = SymmetricKey(size: .bits256)
        let client = FakePhiSyncClient()
        let foreign = try ciphertext(settingEntity(settingKey, true, at: 999), key: SymmetricKey(size: .bits256))
        client.seed(ciphertext: foreign, version: 5)
        defaults.set(false, forKey: settingKey)

        await makeEngine(client, key: key, now: 1_000).pullOnce()

        XCTAssertFalse(defaults.bool(forKey: settingKey))
        XCTAssertEqual(defaults.string(forKey: PhiSyncEngine.entityIdStateKey), "srv-seed")
        XCTAssertTrue(client.commits.isEmpty, "an entity this device cannot read must not be overwritten")
        XCTAssertEqual(client.stored[PhiSyncEntity.clientTagHash]?.ciphertext, foreign)
        // The marker is rewound so the next round sees the entity again and can heal once the
        // right domain key is available.
        XCTAssertNil(defaults.data(forKey: PhiSyncEngine.markerStateKey))
    }

    /// The same protection has to survive a relaunch: the entity id and version persist but the
    /// decrypted baseline does not, so a push that starts from an id with no baseline must
    /// refuse rather than commit over bytes it never read.
    func testPushRefusesWithoutAReadableBaseline() async throws {
        let key = SymmetricKey(size: .bits256)
        let client = FakePhiSyncClient()
        client.seed(ciphertext: try ciphertext(settingEntity(settingKey, true, at: 999), key: SymmetricKey(size: .bits256)),
                    version: 5)
        await makeEngine(client, key: key, now: 1_000).pullOnce()
        XCTAssertEqual(defaults.string(forKey: PhiSyncEngine.entityIdStateKey), "srv-seed")

        // A fresh engine, as after a relaunch: only what UserDefaults kept survives.
        defaults.set(true, forKey: settingKey)
        await makeEngine(client, key: key, now: 2_000).pushLocalSettings()

        XCTAssertTrue(client.commits.isEmpty)
    }

    /// The relaunch shape is not the only one: a device that *has* synced before holds a
    /// decrypted baseline, and the refusal has to survive that too. Once a pull has seen bytes
    /// it cannot read, the baseline it still holds describes an older version of the entity —
    /// keeping it would let the very next debounced local change commit over the unreadable
    /// bytes using the id and version harvested from them.
    func testUnreadableEntityDropsTheBaselineSoLaterLocalChangesRefuse() async throws {
        let key = SymmetricKey(size: .bits256)
        let client = FakePhiSyncClient()
        client.seed(ciphertext: try ciphertext(settingEntity(settingKey, true, at: 999), key: key), version: 5)

        // Round 1: a readable entity, so this device really does hold a baseline.
        await makeEngine(client, key: key, now: 1_000).pullOnce()
        XCTAssertNotNil(defaults.data(forKey: PhiSyncEngine.lastEntityStateKey))

        // A peer re-mints the domain key (or seals with an envelope version this build
        // rejects) and writes a newer version this device cannot open.
        let foreign = try ciphertext(settingEntity(settingKey, false, at: 3_000),
                                     key: SymmetricKey(size: .bits256))
        client.seed(ciphertext: foreign, version: 6)
        let engine = makeEngine(client, key: key, now: 2_000)
        await engine.pullOnce()

        XCTAssertNil(defaults.data(forKey: PhiSyncEngine.lastEntityStateKey),
                     "a baseline that predates bytes we could not read must not be kept")
        XCTAssertEqual(defaults.string(forKey: PhiSyncEngine.entityIdStateKey), "srv-seed",
                       "the id stays, so the push guard stays armed and no create can slip through")

        // T9's debounced UserDefaults.didChangeNotification after a user edit.
        defaults.set(false, forKey: settingKey)
        await engine.handleLocalDefaultsChange()

        XCTAssertTrue(client.commits.isEmpty,
                      "a device that synced before must not publish over an entity it could not read")
        XCTAssertEqual(client.stored[PhiSyncEntity.clientTagHash]?.ciphertext, foreign)
        XCTAssertEqual(defaults.object(forKey: PhiSyncEngine.versionStateKey) as? NSNumber, NSNumber(value: Int64(6)))
    }

    /// Characterization, not a regression guard: this pins the one state where `hasAdopted` and
    /// `hasSyncedBefore` deliberately disagree the *other* way from
    /// `testAHealedCursorStillMergesByTimestampInsteadOfAdoptingWholesale`.
    ///
    /// A device whose only sight of the account's entity was unreadable holds an entity id with
    /// no baseline and no sidecars, so `push` refuses before `SyncableSettings.snapshot` can
    /// stamp anything — and an edit made in that window is adopted over, not merged, once the
    /// entity becomes readable. Merging instead would be the larger loss: with no sidecars
    /// `snapshot` stamps every registered key `now`, so this device's whole local default set
    /// would beat the account's real settings and be published over every other device. If a
    /// later change flips this to a merge, this test is where that decision has to be made
    /// again.
    func testAnUnreadableEntityLaterAdoptsWholesaleOverAnEditMadeInThatWindow() async throws {
        let key = SymmetricKey(size: .bits256)
        let client = FakePhiSyncClient()
        // This device's first and only sight of the account's entity: bytes it cannot open.
        client.seed(ciphertext: try ciphertext(settingEntity(settingKey, false, at: 1_000),
                                               key: SymmetricKey(size: .bits256)),
                    version: 5)

        let engine = makeEngine(client, key: key, now: 2_000)
        await engine.pullOnce()
        XCTAssertEqual(defaults.string(forKey: PhiSyncEngine.entityIdStateKey), "srv-seed",
                       "precondition: an entity id harvested from an entity we could not read")
        XCTAssertNil(defaults.data(forKey: PhiSyncEngine.lastEntityStateKey),
                     "precondition: no baseline, so the push guard is armed")
        XCTAssertNil(defaults.object(forKey: PhiSyncEngine.hasAdoptedStateKey),
                     "precondition: nothing applied and nothing committed, so no settings history")

        // The user flips the setting inside that window. The push guard refuses, and returns
        // before `snapshot` runs — so no sidecar timestamp is stamped for the edited key.
        defaults.set(true, forKey: settingKey)
        await engine.handleLocalDefaultsChange()
        XCTAssertTrue(client.commits.isEmpty,
                      "a device with no readable baseline must not publish over the entity")
        XCTAssertNil(defaults.object(forKey: SyncableSettings.timestampKey(for: settingKey)),
                     "the refused push stamps no timestamp it would then have to defend")

        // A re-minted domain key (or a newer build) makes the same entity readable.
        client.seed(ciphertext: try ciphertext(settingEntity(settingKey, false, at: 1_000), key: key),
                    version: 6)
        await makeEngine(client, key: key, now: 5_000).pullOnce()

        XCTAssertFalse(defaults.bool(forKey: settingKey),
                       "no settings history means the account's entity is adopted wholesale, "
                       + "and the edit made in the window is lost with it")
        XCTAssertTrue(client.commits.isEmpty,
                      "the adopt is the point: none of this device's local defaults is published")
    }

    /// The conflict retry reaches `push` with `allowInitialPull: false`, so the pull's
    /// in-round `mayPublish` short circuit never covers it: only the durable guard does.
    func testConflictRetryRefusesToCommitOverAnEntityThePullCouldNotRead() async throws {
        let key = SymmetricKey(size: .bits256)
        let client = FakePhiSyncClient()
        client.seed(ciphertext: try ciphertext(settingEntity(settingKey, true, at: 999), key: key), version: 5)
        await makeEngine(client, key: key, now: 1_000).pullOnce()

        // The account moved on while this device was editing: the commit conflicts, and the
        // pull the retry runs finds an entity this device cannot open.
        let foreign = try ciphertext(settingEntity(settingKey, false, at: 3_000),
                                     key: SymmetricKey(size: .bits256))
        client.seed(ciphertext: foreign, version: 6)
        client.forcedConflicts = 1
        defaults.set(false, forKey: settingKey)

        await makeEngine(client, key: key, now: 2_000).pushLocalSettings()

        XCTAssertEqual(client.commits.count, 1, "only the first, rejected commit may reach the wire")
        XCTAssertEqual(client.commits[0].baseVersion, 5)
        XCTAssertEqual(client.stored[PhiSyncEntity.clientTagHash]?.ciphertext, foreign,
                       "the retry must not overwrite bytes the pull could not read")
        XCTAssertNil(defaults.data(forKey: PhiSyncEngine.lastEntityStateKey))
    }

    /// The tombstone reason takes the same branch, and needs the same durable refusal: a
    /// device that had synced before must not undelete the account's settings on its next
    /// local edit. (Only a tombstone that outlasts several consecutive pulls is healed — see
    /// `testRepeatedTombstoneLetsALaterLocalChangeRecreateTheEntity`.)
    func testTombstoneAfterASuccessfulSyncBlocksTheNextLocalChange() async throws {
        let key = SymmetricKey(size: .bits256)
        let client = FakePhiSyncClient()
        client.seed(ciphertext: try ciphertext(settingEntity(settingKey, true, at: 999), key: key), version: 5)
        await makeEngine(client, key: key, now: 1_000).pullOnce()

        client.seed(ciphertext: Data(), version: 6, deleted: true)
        let engine = makeEngine(client, key: key, now: 2_000)
        await engine.pullOnce()

        defaults.set(false, forKey: settingKey)
        await engine.handleLocalDefaultsChange()

        XCTAssertTrue(client.commits.isEmpty, "a tombstone must not be resurrected by a later local edit")
        XCTAssertEqual(client.stored[PhiSyncEntity.clientTagHash]?.deleted, true)
    }

    /// A tombstone must not be decrypted or applied, its version is still the base for the next
    /// commit, and the trailing push must not resurrect it: the server's client-tag index
    /// reuses the tombstoned row, so a commit here would undelete the account's settings from
    /// this one device's view.
    func testDeletedRemoteEntityIsNotApplied() async throws {
        let key = SymmetricKey(size: .bits256)
        let client = FakePhiSyncClient()
        client.seed(ciphertext: Data(), version: 7, deleted: true)
        defaults.set(true, forKey: settingKey)

        await makeEngine(client, key: key, now: 1_000).pullOnce()

        XCTAssertTrue(defaults.bool(forKey: settingKey))
        XCTAssertEqual(defaults.object(forKey: PhiSyncEngine.versionStateKey) as? NSNumber, NSNumber(value: Int64(7)))
        XCTAssertTrue(client.commits.isEmpty, "a tombstone must not be resurrected by the trailing push")
        XCTAssertEqual(client.stored[PhiSyncEntity.clientTagHash]?.deleted, true)
    }

    /// Refusing to publish over a tombstone is right, but on its own the refusal is permanent
    /// and account-wide: the server keeps returning the tombstoned row on every replay
    /// (FetchUpdates has no `deleted = false` filter and toSyncEntity emits a non-empty
    /// `id_string`), so the `.absent` self-heal never fires and every device parks its pushes
    /// forever. After `tombstoneHealAfterRounds` consecutive tombstone pulls the entity cursor
    /// is dropped, so the next real local change goes out as a create.
    func testRepeatedTombstoneLetsALaterLocalChangeRecreateTheEntity() async throws {
        let key = SymmetricKey(size: .bits256)
        let client = FakePhiSyncClient()
        client.seed(ciphertext: try ciphertext(settingEntity(settingKey, true, at: 999), key: key), version: 5)
        await makeEngine(client, key: key, now: 1_000).pullOnce()

        // The row is deleted server-side, and every later replay hands back the same tombstone.
        client.seed(ciphertext: Data(), version: 6, deleted: true)
        let engine = makeEngine(client, key: key, now: 2_000)
        await engine.pullOnce()
        await engine.pullOnce()
        XCTAssertEqual(defaults.string(forKey: PhiSyncEngine.entityIdStateKey), "srv-seed",
                       "two rounds are not evidence enough to re-create the account's settings")

        await engine.pullOnce()
        XCTAssertNil(defaults.string(forKey: PhiSyncEngine.entityIdStateKey),
                     "the third consecutive tombstone drops the entity cursor")
        XCTAssertTrue(client.commits.isEmpty, "arming the heal must not publish anything by itself")
        XCTAssertEqual(client.stored[PhiSyncEntity.clientTagHash]?.deleted, true)

        // Only an explicit local change takes the create path.
        defaults.set(false, forKey: settingKey)
        await engine.handleLocalDefaultsChange()

        XCTAssertEqual(client.commits.count, 1)
        XCTAssertNil(client.commits[0].entityId, "a create, resolved by the client-tag index")
        XCTAssertEqual(client.commits[0].baseVersion, 0)
        XCTAssertEqual(client.stored[PhiSyncEntity.clientTagHash]?.deleted, false)
        XCTAssertEqual(try decryptSetting(client.commits[0].ciphertext, key: key).values[settingKey]?.boolValue, false)
        XCTAssertNil(defaults.object(forKey: PhiSyncEngine.tombstoneRoundsStateKey),
                     "a successful commit ends the streak")
    }

    /// Healing the cursor says "the settings no longer live in that row", never "this device
    /// has never synced". The two were the same predicate once, and a device whose cursor had
    /// been healed adopted the next readable entity wholesale — silently discarding a local
    /// edit whose debounced push had not run yet. `hasAdopted` survives `clearEntityCursor()`,
    /// so the field-level merge still decides.
    func testAHealedCursorStillMergesByTimestampInsteadOfAdoptingWholesale() async throws {
        let key = SymmetricKey(size: .bits256)
        let client = FakePhiSyncClient()
        client.seed(ciphertext: try ciphertext(settingEntity(settingKey, false, at: 1_000), key: key), version: 5)
        let engine = makeEngine(client, key: key, now: 2_000)
        await engine.pullOnce()
        XCTAssertFalse(defaults.bool(forKey: settingKey))

        // The row stays tombstoned long enough to arm the heal, which drops the entity cursor.
        client.seed(ciphertext: Data(), version: 6, deleted: true)
        for _ in 0..<3 { await engine.pullOnce() }
        XCTAssertNil(defaults.string(forKey: PhiSyncEngine.entityIdStateKey),
                     "precondition: the heal armed and dropped the entity cursor")
        XCTAssertNotNil(defaults.object(forKey: PhiSyncEngine.hasAdoptedStateKey),
                        "the account's settings history is not part of the entity cursor")

        // The user flips the setting; before the debounced push runs, a peer re-creates the
        // row with an older value and the periodic pull gets there first.
        defaults.set(true, forKey: settingKey)
        client.seed(ciphertext: try ciphertext(settingEntity(settingKey, false, at: 3_000), key: key),
                    version: 7, entityId: "srv-new")
        await makeEngine(client, key: key, now: 5_000).pullOnce()

        XCTAssertTrue(defaults.bool(forKey: settingKey),
                      "a healed cursor must not turn the next pull into a wholesale adopt")
        XCTAssertEqual(client.commits.count, 1, "the newer local value is published back")
        let committed = try decryptSetting(client.commits[0].ciphertext, key: key)
        XCTAssertEqual(committed.values[settingKey]?.boolValue, true)
        XCTAssertEqual(committed.values[settingKey]?.updatedAtMs, 5_000)
    }

    /// Settings history is not only made by pulls: a device that created the account's entity
    /// stamped a sidecar timestamp for every registered key on the way, so its later pulls must
    /// merge too. (An `apply`-only flag would make this device adopt the peer's older value.)
    func testADeviceThatCreatedTheEntityMergesLaterPullsInsteadOfAdopting() async throws {
        let key = SymmetricKey(size: .bits256)
        let client = FakePhiSyncClient()
        defaults.set(true, forKey: settingKey)
        await makeEngine(client, key: key, now: 1_000).pushLocalSettings()
        XCTAssertEqual(client.commits.count, 1, "precondition: this device created the entity")

        // A peer overwrites the row with a value that is older than this device's edit.
        client.seed(ciphertext: try ciphertext(settingEntity(settingKey, false, at: 500), key: key),
                    version: 200, entityId: "srv-1")
        await makeEngine(client, key: key, now: 3_000).pullOnce()

        XCTAssertTrue(defaults.bool(forKey: settingKey),
                      "the value this device committed is newer and must win the field-level merge")
    }

    /// The streak has to be consecutive. A readable entity in between resets it, so a fresh
    /// tombstone starts counting again and the durable refusal still holds.
    func testAReadableEntityResetsTheTombstoneStreak() async throws {
        let key = SymmetricKey(size: .bits256)
        let client = FakePhiSyncClient()
        client.seed(ciphertext: try ciphertext(settingEntity(settingKey, true, at: 999), key: key), version: 5)
        let engine = makeEngine(client, key: key, now: 2_000)
        await engine.pullOnce()

        client.seed(ciphertext: Data(), version: 6, deleted: true)
        await engine.pullOnce()
        await engine.pullOnce()

        // A peer re-creates the settings entity before the heal arms.
        client.seed(ciphertext: try ciphertext(settingEntity(settingKey, false, at: 3_000), key: key), version: 7)
        await engine.pullOnce()
        XCTAssertNil(defaults.object(forKey: PhiSyncEngine.tombstoneRoundsStateKey))

        // Deleted again: one tombstone is not three, so a local change is still refused.
        client.seed(ciphertext: Data(), version: 8, deleted: true)
        await engine.pullOnce()
        XCTAssertEqual(defaults.string(forKey: PhiSyncEngine.entityIdStateKey), "srv-seed")

        defaults.set(true, forKey: settingKey)
        await engine.handleLocalDefaultsChange()

        XCTAssertTrue(client.commits.isEmpty)
        XCTAssertEqual(client.stored[PhiSyncEntity.clientTagHash]?.deleted, true)
    }

    /// Only a tombstone is healable: it carries no content. Bytes this device merely cannot
    /// decrypt are real settings, so no number of rounds may drop the cursor and let a
    /// `baseVersion = 0` create overwrite them.
    func testUndecryptableEntityIsNeverHealedByTheTombstoneCounter() async throws {
        let key = SymmetricKey(size: .bits256)
        let client = FakePhiSyncClient()
        let foreign = try ciphertext(settingEntity(settingKey, true, at: 999), key: SymmetricKey(size: .bits256))
        client.seed(ciphertext: foreign, version: 5)
        let engine = makeEngine(client, key: key, now: 1_000)

        for _ in 0..<4 { await engine.pullOnce() }

        XCTAssertEqual(defaults.string(forKey: PhiSyncEngine.entityIdStateKey), "srv-seed")
        XCTAssertNil(defaults.object(forKey: PhiSyncEngine.tombstoneRoundsStateKey))

        defaults.set(false, forKey: settingKey)
        await engine.handleLocalDefaultsChange()

        XCTAssertTrue(client.commits.isEmpty)
        XCTAssertEqual(client.stored[PhiSyncEntity.clientTagHash]?.ciphertext, foreign)
    }

    /// A full replay that carries no settings entity proves the row is gone (a namespace
    /// change, a targeted delete, a partial restore). The stale id goes with it, otherwise
    /// every later commit is an update the server answers with INVALID_MESSAGE forever.
    func testFullReplayWithoutTheEntityDropsTheStaleCursor() async throws {
        let key = SymmetricKey(size: .bits256)
        let client = FakePhiSyncClient()
        defaults.set("srv-gone", forKey: PhiSyncEngine.entityIdStateKey)
        defaults.set(NSNumber(value: Int64(42)), forKey: PhiSyncEngine.versionStateKey)
        defaults.set(try settingEntity(settingKey, false, at: 1_000).serializedData(),
                     forKey: PhiSyncEngine.lastEntityStateKey)
        defaults.set(true, forKey: settingKey)

        await makeEngine(client, key: key, now: 2_000).pullOnce()

        XCTAssertEqual(client.commits.count, 1, "the round falls back to a create")
        XCTAssertNil(client.commits[0].entityId)
        XCTAssertEqual(client.commits[0].baseVersion, 0)
        XCTAssertEqual(defaults.string(forKey: PhiSyncEngine.entityIdStateKey), "srv-1")
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

    /// INVALID_MESSAGE means the server has no row for the id this commit names (pgx.ErrNoRows
    /// on the update path, or a data_type mismatch). NOT_MY_BIRTHDAY never fires for it, and an
    /// incremental GetUpdates returns nothing, so without dropping the cursor the device would
    /// resend the same rejected id forever and never sync again.
    func testCommitRejectedAsInvalidMessageDropsTheCursor() async throws {
        let key = SymmetricKey(size: .bits256)
        let client = FakePhiSyncClient()
        client.seed(ciphertext: try ciphertext(settingEntity(settingKey, false, at: 1_000), key: key), version: 5)
        let engine = makeEngine(client, key: key, now: 2_000)
        await engine.pullOnce()

        defaults.set(true, forKey: settingKey)
        client.commitErrorOnce = PhiSyncProtocolError.commitRejected(.invalidMessage)
        await engine.pushLocalSettings()

        XCTAssertEqual(client.commits.count, 1)
        for stateKey in PhiSyncEngine.stateKeys {
            XCTAssertNil(defaults.object(forKey: stateKey), "\(stateKey) survived INVALID_MESSAGE")
        }
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

    // MARK: - Serialization

    /// R8's invariant, which actor isolation alone does not provide: Swift actors are
    /// reentrant, so a round parked at an `await` would otherwise let the next one in. A local
    /// change raised while a pull is suspended inside `getUpdates` must wait for that pull's
    /// whole round — cursor writes included — before it commits anything.
    func testRoundsDoNotInterleaveWhileAPullIsSuspended() async throws {
        let key = SymmetricKey(size: .bits256)
        let client = FakePhiSyncClient()
        client.seed(ciphertext: try ciphertext(settingEntity(settingKey, false, at: 1_000), key: key), version: 5)
        // A first round establishes the cursor and the baseline.
        await makeEngine(client, key: key, now: 1_000).pullOnce()

        let arrived = Gate()
        let release = Gate()
        client.arrivedInGetUpdates = arrived
        client.getUpdatesGate = release

        let engine = makeEngine(client, key: key, now: 3_000)
        let pull = Task { await engine.pullOnce() }
        await arrived.wait()                     // the pull is now parked inside getUpdates

        defaults.set(true, forKey: settingKey)   // a user edit lands mid-round
        let push = Task { await engine.handleLocalDefaultsChange() }
        for _ in 0..<32 { await Task.yield() }
        XCTAssertTrue(client.commits.isEmpty, "the queued push must not run while the pull is parked")

        await release.open()
        await pull.value
        await push.value

        XCTAssertEqual(client.commits.count, 1)
        XCTAssertEqual(client.callLog.filter { $0 != "getUpdates.begin" },
                       ["getUpdates.end", "getUpdates.end", "commit"],
                       "the commit lands after the parked pull finished its round, not during it")
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

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
    ///
    /// **The wait is bounded.** Every call site depends on the engine actually reaching the
    /// instrumented `getUpdates` / `commit` under whatever gating condition the case set up.
    /// If that condition ever stops matching what the case assumed, an unbounded
    /// `withCheckedContinuation` is never resumed -- and XCTest applies no timeout to an
    /// `await` inside a test body, so the failure would present as a stuck suite rather than
    /// a red test. On expiry the waiter is resumed with a failure, `XCTFail` is attributed to
    /// the caller's own `wait()` line, and control returns. The success path is unchanged:
    /// `open()` still resumes every waiter, and a `wait()` after `open()` still returns at once.
    actor Gate {
        /// Ten seconds. Between a park and its `open()` these cases do a handful of
        /// `Task.yield()`s and one in-memory round, so spending this is only ever possible if
        /// the gate is never going to open at all.
        static let defaultTimeout: TimeInterval = 10

        private var isOpen = false
        private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]

        func open() {
            guard !isOpen else { return }
            isOpen = true
            for waiter in waiters.values { waiter.resume(returning: true) }
            waiters.removeAll()
        }

        func wait(timeout: TimeInterval = Gate.defaultTimeout,
                  file: StaticString = #filePath,
                  line: UInt = #line) async {
            guard !isOpen else { return }
            let id = UUID()
            // Detached on purpose: the deadline must not inherit this actor's isolation, or it
            // would be ordered behind whatever is already queued on it.
            let deadline = Task.detached { [self] in
                do { try await Task.sleep(nanoseconds: UInt64(max(timeout, 0) * 1_000_000_000)) }
                catch { return }                 // cancelled -- the gate opened first
                await expire(id)
            }
            // The continuation is registered synchronously inside this closure, before the
            // actor is ever yielded, so `expire` cannot arrive ahead of it.
            let opened = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                waiters[id] = continuation
            }
            deadline.cancel()
            if !opened {
                XCTFail("gate never opened within \(timeout)s", file: file, line: line)
            }
        }

        /// Expiry releases *this* waiter only. The gate stays shut and every other waiter keeps
        /// its own deadline, so one timed-out site cannot silently unpark the rest.
        private func expire(_ id: UUID) {
            waiters.removeValue(forKey: id)?.resume(returning: false)
        }
    }

    /// Lets a test reach the engine from inside a closure the engine itself calls (`now()`),
    /// which is the only seam that runs *between* a round's entry guard and its writes.
    ///
    /// The back-reference is `weak` on purpose: the engine owns the `now` closure, and the
    /// closure captures the holder, so a strong `engine` here would close the cycle
    /// engine -> now -> holder -> engine and leak the engine (with its stubbed key provider,
    /// fake client and entity bytes) for the life of the test bundle. The test case holds its
    /// own strong `engine` local for the whole case, so this stays non-nil while `now()` runs.
    final class EngineHolder: @unchecked Sendable {
        weak var engine: PhiSyncEngine?
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
            /// M3-2: "phi-settings", or the constant "phi-space".
            let name: String
            /// M3-2: nil for a tombstone.
            let ciphertext: Data?
            let deleted: Bool
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
        private(set) var commits: [CommitCall] = []   // name unchanged on purpose

        var storeBirthday = "birthday-1"
        var rejectStaleStoreBirthday = false
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
        /// AM-2: the `Date` response header this fake reports, as epoch ms. nil is the default
        /// (and the protocol extension's default), which leaves the correction off entirely, so
        /// every test that does not set it behaves exactly as it did before AM-2.
        var lastServerDateMs: Int64?
        /// Opened as soon as `getUpdates` is entered, so a test can wait for a round to be
        /// parked inside the network call.
        var arrivedInGetUpdates: Gate?
        /// Awaited inside `getUpdates`: while it is shut, the calling round is suspended.
        var getUpdatesGate: Gate?
        /// Ordered log of what the engine did on the wire, so a test can assert that a commit
        /// happened after a parked pull finished rather than during it.
        private(set) var callLog: [String] = []
        /// M3-2: while positive, every `getUpdates` answers `changes_remaining = true` and
        /// spends one page of this supply, so the only thing that can end a pull is the
        /// engine's own `maxPullPages` budget. Set it above the engine's total page budget
        /// across all its follow-up rounds to keep a drain unfinished for a whole test phase.
        var pageBudgetExhaustsAfter: Int?
        /// M3-2: the next `getUpdates` answers NOT_MY_BIRTHDAY, then clears itself — the shape
        /// the server uses when the store this device tracks is gone.
        var throwNotMyBirthdayOnce = false
        /// M3-2: answer `pages` calls normally and throw `error` on the one after them — the
        /// "page 1 landed, page 2 failed" shape a round needs to be interrupted *after* it has
        /// already advanced the shared marker. `getUpdatesErrorOnce` cannot express it: it
        /// fires on the round's very first call, before anything is persisted.
        var getUpdatesErrorAfterPages: (pages: Int, error: Error)?
        /// M3-2: while set, every commit ENTRY is answered INVALID_MESSAGE as an
        /// outcome and the store is left untouched — the per-entry shape the real
        /// server uses. Deliberately not a throw: a throw abandons the whole
        /// batch, which is precisely what a Space batch must survive.
        var forceInvalidMessage = false
        /// M3-2: one-shot per tag. An entry whose `client_tag_hash` is in the set
        /// is answered CONFLICT, the hash is removed and the store is left
        /// untouched, so the scoped retry that follows it succeeds.
        var conflictOnceForTagHashes: Set<String> = []
        /// The phi type's server refuses a CREATE whose client tag already names a LIVE row
        /// holding different content: it answers CONFLICT with that row's id and version instead
        /// of overwriting it. Identical content is still SUCCESS at the existing version, and a
        /// tombstoned row still undeletes. Off by default, so every test written against the
        /// blind client-tag upsert keeps its behaviour.
        var conflictsOnLiveCreate = false
        /// Tag hashes whose create counts as content the live row already holds, so the store
        /// answers SUCCESS at the EXISTING version without writing. Ciphertext equality cannot
        /// express this from a test: sealing is nondeterministic, so two seals of one payload
        /// differ. Only read while `conflictsOnLiveCreate` is on.
        var identicalCreateTagHashes: Set<String> = []
        /// Answer this many further commits for a tag with a BARE conflict — one that names no
        /// row — then behave normally. `conflictOnceForTagHashes` cannot express a scoped retry
        /// conflicting a second time, and `forcedConflicts` is not tag-scoped, so a Space commit
        /// riding the same round would spend it.
        var bareConflictRoundsForTagHashes: [String: Int] = [:]
        /// M3-2: the commit-side twin of `arrivedInGetUpdates` / `getUpdatesGate`,
        /// narrowed to one tag so the settings entity riding the same batch list
        /// cannot trip it. A batch containing this hash opens `arrivedInCommit`
        /// and then waits on `commitGate` BEFORE it answers anything, which is
        /// what parks a Space push inside its own table window
        /// (`pushSpaces` loads the table before the batch loop and writes it
        /// back after).
        var gatedCommitTagHash: String?
        var arrivedInCommit: Gate?
        var commitGate: Gate?
        /// M3-3: entries whose `client_tag_hash` is in here are answered
        /// INVALID_MESSAGE **for good** and the store is left untouched — the shape
        /// a tombstone the account keeps rejecting has. Unlike `forceInvalidMessage`
        /// it is scoped to a tag, so one refused entry can sit next to twenty-four
        /// accepted ones in the same batch, which is what §5.3's "an ancestor waits
        /// for its descendants to be `.applied`" needs to be observable at all.
        var refuseCommitsForTagHashes: Set<String> = []
        /// M3-3: every `getUpdates` answers `changes_remaining = true` without
        /// spending a supply, so a drain never finishes. `pageBudgetExhaustsAfter`
        /// cannot express it — it is a countdown, and the engine's follow-up rounds
        /// outlive any fixed number a test would pick.
        var keepReportingChangesRemaining = false
        /// M3-4a / B-2: paginate by received marker, matching WHERE version > marker,
        /// rather than call count. Each newMarker is a decimal watermark at least as high
        /// as every entity version on its page. Empty disables this mode and preserves
        /// scriptedPages/stored behavior. Repeated markers return the same page, modeling
        /// replay without marker advancement and detecting CASE B2-13's deadlock (R-M3-4a-76).
        var pagesByMarker: [Page] = []
        /// M3-4a / B-2: arrivedInGetUpdates/getUpdatesGate apply from call N, counting
        /// from 1; nil preserves every-call behavior. Block the automatic follow-up
        /// round after page_budget_exhausted at its first request so the preceding
        /// round's outcome and store counts can be read deterministically before further work.
        var gateGetUpdatesFromCall: Int?

        /// M3-3: a client whose drain never ends, for the guard ① cases. The key is
        /// taken so a caller can seed readable rows into it afterwards.
        static func alwaysMorePages(key: SymmetricKey) -> FakePhiSyncClient {
            _ = key
            let client = FakePhiSyncClient()
            client.keepReportingChangesRemaining = true
            return client
        }

        func seed(ciphertext: Data, version: Int64, entityId: String = "srv-seed", deleted: Bool = false) {
            stored[PhiSyncEntity.settingsClientTagHash] = Stored(entityId: entityId, version: version,
                                                                 ciphertext: ciphertext, deleted: deleted)
        }

        /// M3-2: seed a row under an arbitrary `client_tag_hash` — a Space's, or a tag this
        /// build cannot name at all. The id defaults to a fresh server-assigned one, because
        /// the update path below matches on `row.entityId == entityId` and a shared literal id
        /// would make two seeded rows indistinguishable.
        func seed(tagHash: String, ciphertext: Data, version: Int64,
                  entityId: String? = nil, deleted: Bool = false) {
            let id = entityId ?? { idCounter += 1; return "srv-\(idCounter)" }()
            stored[tagHash] = Stored(entityId: id, version: version,
                                     ciphertext: ciphertext, deleted: deleted)
        }

        /// M3-2: replace a seeded row's payload and version while KEEPING the id
        /// the server assigned it. `seed(tagHash:…)` mints a fresh `srv-N` by
        /// default, so re-seeding through it would make the engine's stored
        /// entity id stop matching the row it points at.
        func reseed(tagHash: String, ciphertext: Data, version: Int64) {
            let id = stored[tagHash]?.entityId ?? { idCounter += 1; return "srv-\(idCounter)" }()
            stored[tagHash] = Stored(entityId: id, version: version,
                                     ciphertext: ciphertext, deleted: false)
        }

        /// M3-2: the id the server assigned to a seeded row, so a test can pin
        /// the cursor the engine wrote against it (`stored` is `private(set)`).
        func entityId(forTagHash tagHash: String) -> String { stored[tagHash]?.entityId ?? "" }

        func getUpdates(marker: Data?, storeBirthday: String) async throws
            -> (entities: [PhiRemoteEntity], newMarker: Data, storeBirthday: String, changesRemaining: Bool) {
            getUpdatesCalls.append((marker, storeBirthday))
            callLog.append("getUpdates.begin")
            if gateGetUpdatesFromCall.map({ getUpdatesCalls.count >= $0 }) ?? true {
                if let arrivedInGetUpdates { await arrivedInGetUpdates.open() }
                if let getUpdatesGate { await getUpdatesGate.wait() }
            }
            defer { callLog.append("getUpdates.end") }
            if rejectStaleStoreBirthday, !storeBirthday.isEmpty, storeBirthday != self.storeBirthday {
                throw PhiSyncProtocolError.notMyBirthday
            }
            if let error = getUpdatesErrorOnce {
                getUpdatesErrorOnce = nil
                throw error
            }
            if throwNotMyBirthdayOnce {
                throwNotMyBirthdayOnce = false
                throw PhiSyncProtocolError.notMyBirthday
            }
            if var scheduled = getUpdatesErrorAfterPages {
                guard scheduled.pages > 0 else {
                    getUpdatesErrorAfterPages = nil
                    throw scheduled.error
                }
                scheduled.pages -= 1
                getUpdatesErrorAfterPages = scheduled
            }
            if !pagesByMarker.isEmpty {
                // After getUpdatesErrorAfterPages but before scriptedPages: errors count calls,
                // pagination uses watermarks. No matching page returns empty with the unchanged marker and no more changes.
                let from = Self.watermark(marker)
                guard let page = pagesByMarker.first(where: { Self.watermark($0.newMarker) > from }) else {
                    return ([], marker ?? Data(), self.storeBirthday, false)
                }
                return (page.entities, page.newMarker, self.storeBirthday,
                        page.changesRemaining || keepReportingChangesRemaining)
            }
            if !scriptedPages.isEmpty {
                let page = scriptedPages.removeFirst()
                return (page.entities, page.newMarker, self.storeBirthday,
                        page.changesRemaining || keepReportingChangesRemaining)
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
            if let budget = pageBudgetExhaustsAfter, budget > 0 {
                pageBudgetExhaustsAfter = budget - 1
                return (fresh, newMarker, self.storeBirthday, true)
            }
            return (fresh, newMarker, self.storeBirthday, keepReportingChangesRemaining)
        }

        /// One store write per entry, outcomes paired to `entries` by index — like the real
        /// server, which allocates `responses` at `len(entries)` and writes each result back at
        /// its own index. A *throw* still abandons the whole batch, which for the single-entry
        /// settings path is exactly today's behaviour.
        func commit(entries: [PhiCommitEntry], storeBirthday: String) async throws -> [PhiCommitOutcome] {
            if let hash = gatedCommitTagHash, entries.contains(where: { $0.clientTagHash == hash }) {
                if let arrivedInCommit { await arrivedInCommit.open() }
                if let commitGate { await commitGate.wait() }
            }
            var outcomes: [PhiCommitOutcome] = []
            for entry in entries {
                let clientTagHash = entry.clientTagHash
                let baseVersion = entry.baseVersion
                // A tombstone carries no ciphertext; the server backfills the type's default
                // specifics, so the stored row keeps empty bytes rather than a nil.
                let ciphertext = entry.ciphertext ?? Data()
                commits.append(CommitCall(entityId: entry.entityId, clientTagHash: clientTagHash,
                                          name: entry.name, ciphertext: entry.ciphertext,
                                          deleted: entry.deleted, baseVersion: baseVersion,
                                          storeBirthday: storeBirthday))
                callLog.append("commit")
                if let error = commitErrorOnce {
                    commitErrorOnce = nil
                    throw error
                }
                if forceInvalidMessage || refuseCommitsForTagHashes.contains(clientTagHash) {
                    outcomes.append(.invalidMessage)
                    continue
                }
                // These knobs model a bare CONFLICT that names no row, the shape every case
                // written before the create conflict existed was built against.
                if conflictOnceForTagHashes.remove(clientTagHash) != nil {
                    outcomes.append(.conflict(entityId: nil,
                                              serverVersion: stored[clientTagHash]?.version))
                    continue
                }
                if forcedConflicts > 0 {
                    forcedConflicts -= 1
                    outcomes.append(.conflict(entityId: nil,
                                              serverVersion: stored[clientTagHash]?.version))
                    continue
                }
                if let remaining = bareConflictRoundsForTagHashes[clientTagHash], remaining > 0 {
                    bareConflictRoundsForTagHashes[clientTagHash] = remaining - 1
                    outcomes.append(.conflict(entityId: nil,
                                              serverVersion: stored[clientTagHash]?.version))
                    continue
                }
                // A create carries no base version. An entry that names no entity but a nonzero
                // one is illegal, and the server answers INVALID_MESSAGE — which is what makes a
                // cursor holding a version without an identity fatal rather than merely wasteful.
                if entry.entityId == nil, baseVersion != 0 {
                    outcomes.append(.invalidMessage)
                    continue
                }
                // A create over a live row the client tag already names: refuse it and hand back
                // the row's identity and version, so the retry can be an update. Identical
                // content is not a disagreement and answers SUCCESS at the existing version; a
                // tombstoned row still undeletes through the create path below. Checked before
                // the version sequence advances, so an unchanged store leaves no gap in it.
                if conflictsOnLiveCreate, entry.entityId == nil, !entry.deleted,
                   let row = stored[clientTagHash], !row.deleted {
                    if row.ciphertext == ciphertext || identicalCreateTagHashes.contains(clientTagHash) {
                        outcomes.append(.applied(entityId: row.entityId, version: row.version,
                                                 storeBirthday: self.storeBirthday))
                    } else {
                        outcomes.append(.conflict(entityId: row.entityId,
                                                  serverVersion: row.version))
                    }
                    continue
                }
                nextVersion += 1
                if let entityId = entry.entityId {
                    // Update path: the row must exist and the base version must match.
                    guard var row = stored[clientTagHash], row.entityId == entityId else {
                        throw PhiSyncProtocolError.commitRejected(.invalidMessage)
                    }
                    guard row.version == baseVersion else {
                        outcomes.append(.conflict(entityId: row.entityId,
                                                  serverVersion: row.version))
                        continue
                    }
                    row.version = nextVersion
                    row.ciphertext = ciphertext
                    row.deleted = entry.deleted
                    stored[clientTagHash] = row
                    outcomes.append(.applied(entityId: entityId, version: nextVersion,
                                             storeBirthday: self.storeBirthday))
                    continue
                }
                // Create path: ON CONFLICT (client_tag_hash) DO UPDATE — it overwrites blindly,
                // which is exactly why the engine must pull before its first commit.
                let id = stored[clientTagHash]?.entityId ?? { idCounter += 1; return "srv-\(idCounter)" }()
                stored[clientTagHash] = Stored(entityId: id, version: nextVersion,
                                               ciphertext: ciphertext, deleted: entry.deleted)
                outcomes.append(.applied(entityId: id, version: nextVersion,
                                         storeBirthday: self.storeBirthday))
            }
            return outcomes
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
                            now: Int64, paired: Bool = true) -> PhiSyncEngine {
        PhiSyncEngine(domainKeys: StubDomainKeys(key: key),
                      client: client,
                      defaults: defaults,
                      deviceKeyId: "devA", pairingComplete: paired,
                      settings: registry(settingKey),
                      now: { now })
    }

    func testUnpairedEngineAllowsOnlyReadOnlyPreview() async throws {
        let client = FakePhiSyncClient()
        let engine = makeEngine(client, key: SymmetricKey(size: .bits256), now: 100, paired: false)
        let marker = Data([7, 8])
        defaults.set(marker, forKey: PhiSyncEngine.markerStateKey)
        await engine.pullOnce()
        await engine.pushLocalSettings()
        await engine.handleLocalDefaultsChange()
        await engine.handleLocalSpacesChange()
        await engine.handleLocalOwnedChange(label: "bookmarks")
        await engine.runRetentionSweep()
        XCTAssertTrue(client.getUpdatesCalls.isEmpty)
        XCTAssertTrue(client.commits.isEmpty)
        XCTAssertEqual(defaults.data(forKey: PhiSyncEngine.markerStateKey), marker)
        _ = await engine.previewAccountSpaces()
        XCTAssertFalse(client.getUpdatesCalls.isEmpty)
        XCTAssertTrue(client.commits.isEmpty)
        XCTAssertNil(engine.statusSnapshot.lastSuccess)
        await engine.enableAfterPairing()
        await engine.pullOnce()
        XCTAssertGreaterThan(client.getUpdatesCalls.count, 1)
    }

    func testRejectedCommitNeverReportsSuccess() async throws {
        let client = FakePhiSyncClient()
        client.commitErrorOnce = PhiSyncProtocolError.malformedResponse
        let engine = makeEngine(client, key: SymmetricKey(size: .bits256), now: 100)
        defaults.set("local", forKey: settingKey)
        await engine.pushLocalSettings()
        XCTAssertNotEqual(engine.statusSnapshot.phase, .upToDate)
        XCTAssertNil(engine.statusSnapshot.lastSuccess)
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

    /// The stored version is the base the next commit sends, so a page that re-serves the
    /// settings entity at an older version must not lower it — that base would conflict for
    /// nothing. The owned kinds take `max(version)` for the same reason (`harvestTriple`).
    func testAReservedOlderSettingsPageDoesNotLowerTheStoredVersion() async throws {
        let key = SymmetricKey(size: .bits256)
        let client = FakePhiSyncClient()
        let bytes = try ciphertext(settingEntity(settingKey, true, at: 999), key: key)
        client.seed(ciphertext: bytes, version: 9)
        await makeEngine(client, key: key, now: 1_000).pullOnce()
        XCTAssertEqual(defaults.object(forKey: PhiSyncEngine.versionStateKey) as? NSNumber,
                       NSNumber(value: Int64(9)))

        // The same entity comes back on a later page, at a version the device is already past.
        client.scriptedPages = [
            .init(entities: [PhiRemoteEntity(entityId: "srv-seed",
                                             clientTagHash: PhiSyncEntity.settingsClientTagHash,
                                             version: 4, ciphertext: bytes, deleted: false)],
                  newMarker: Data("10".utf8), changesRemaining: false),
        ]
        await makeEngine(client, key: key, now: 2_000).pullOnce()

        XCTAssertEqual(defaults.object(forKey: PhiSyncEngine.versionStateKey) as? NSNumber,
                       NSNumber(value: Int64(9)),
                       "a re-served page must not rewind the base version of the next commit")
        XCTAssertTrue(client.commits.isEmpty, "re-serving what was already applied publishes nothing")
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
        let committed = try decryptSetting(try XCTUnwrap(client.commits[0].ciphertext), key: key)
        XCTAssertEqual(committed.values[settingKey]?.boolValue, true)
        // The edit was made with no sidecar of its own, so the snapshot this pull takes is what
        // first stamps it — at the round's `now`, 3_000, not at the remote's 2_000. (Contrast
        // `testALocalEditSurvivesAnInvalidMessageRejection`, where an earlier refused push had
        // already stamped the sidecar and the later round has to preserve *that* timestamp.)
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

        let engine = makeEngine(client, key: key, now: 1_000)
        await engine.pullOnce()
        XCTAssertEqual(engine.statusSnapshot.phase, .needsAttention)
        await engine.pullOnce()
        XCTAssertEqual(engine.statusSnapshot.phase, .needsAttention)

        XCTAssertFalse(defaults.bool(forKey: settingKey))
        XCTAssertEqual(defaults.string(forKey: PhiSyncEngine.entityIdStateKey), "srv-seed")
        XCTAssertTrue(client.commits.isEmpty, "an entity this device cannot read must not be overwritten")
        XCTAssertEqual(client.stored[PhiSyncEntity.settingsClientTagHash]?.ciphertext, foreign)
        // Review A3: the marker is NOT rewound — it is shared with every other kind, and a
        // rewind re-downloaded the whole type every round. The refusal is recorded instead.
        XCTAssertNotNil(defaults.data(forKey: PhiSyncEngine.markerStateKey))
        XCTAssertNotNil(defaults.data(forKey: PhiSyncEngine.unreadableSettingsStateKey))
    }

    /// Review A3: the record of an unreadable entity is what lets the engine re-read it once
    /// something that could make it readable has changed. A pull under a different domain key
    /// replays the type from the beginning exactly once, applies the entity, and forgets the
    /// record; a pull under the same key does not replay at all.
    func testAnUndecryptableEntityIsReReadOnceTheDomainKeyChanges() async throws {
        let rightKey = SymmetricKey(size: .bits256)
        let wrongKey = SymmetricKey(size: .bits256)
        let client = FakePhiSyncClient()
        client.seed(ciphertext: try ciphertext(settingEntity(settingKey, true, at: 999), key: rightKey), version: 5)
        defaults.set(false, forKey: settingKey)

        await makeEngine(client, key: wrongKey, now: 1_000).pullOnce()
        XCTAssertFalse(defaults.bool(forKey: settingKey))
        let markerAfterRefusal = defaults.data(forKey: PhiSyncEngine.markerStateKey)
        XCTAssertNotNil(markerAfterRefusal)

        // Same key: nothing has changed that could make the bytes readable, so no replay.
        await makeEngine(client, key: wrongKey, now: 2_000).pullOnce()
        XCTAssertEqual(client.getUpdatesCalls.last?.marker, markerAfterRefusal)
        XCTAssertNotNil(defaults.data(forKey: PhiSyncEngine.unreadableSettingsStateKey))

        // The right key arrives (a re-mint this device has now caught up with): one replay.
        await makeEngine(client, key: rightKey, now: 3_000).pullOnce()
        XCTAssertNil(client.getUpdatesCalls.last?.marker, "the heal replays the type from the beginning")
        XCTAssertTrue(defaults.bool(forKey: settingKey), "the entity is applied once it can be read")
        XCTAssertNil(defaults.data(forKey: PhiSyncEngine.unreadableSettingsStateKey))
        XCTAssertNotNil(defaults.data(forKey: PhiSyncEngine.lastEntityStateKey), "the baseline is re-established")
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
        XCTAssertEqual(client.stored[PhiSyncEntity.settingsClientTagHash]?.ciphertext, foreign)
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

    /// The peer changes the entity after preflight. The conflict pull must retain the
    /// unreadable-entity guard when it reaches the scoped retry.
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
        client.scriptedPages = [.init(entities: [], newMarker: Data("5".utf8), changesRemaining: false)]
        client.forcedConflicts = 1
        defaults.set(false, forKey: settingKey)

        await makeEngine(client, key: key, now: 2_000).pushLocalSettings()

        XCTAssertEqual(client.commits.count, 1, "only the first, rejected commit may reach the wire")
        XCTAssertEqual(client.commits[0].baseVersion, 5)
        XCTAssertEqual(client.stored[PhiSyncEntity.settingsClientTagHash]?.ciphertext, foreign,
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
        XCTAssertEqual(client.stored[PhiSyncEntity.settingsClientTagHash]?.deleted, true)
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
        XCTAssertEqual(client.stored[PhiSyncEntity.settingsClientTagHash]?.deleted, true)
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
        XCTAssertEqual(client.stored[PhiSyncEntity.settingsClientTagHash]?.deleted, true)

        // Only an explicit local change takes the create path.
        defaults.set(false, forKey: settingKey)
        await engine.handleLocalDefaultsChange()

        XCTAssertEqual(client.commits.count, 1)
        XCTAssertNil(client.commits[0].entityId, "a create, resolved by the client-tag index")
        XCTAssertEqual(client.commits[0].baseVersion, 0)
        XCTAssertEqual(client.stored[PhiSyncEntity.settingsClientTagHash]?.deleted, false)
        XCTAssertEqual(try decryptSetting(try XCTUnwrap(client.commits[0].ciphertext), key: key).values[settingKey]?.boolValue, false)
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
        let committed = try decryptSetting(try XCTUnwrap(client.commits[0].ciphertext), key: key)
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
        XCTAssertEqual(client.stored[PhiSyncEntity.settingsClientTagHash]?.deleted, true)
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
        XCTAssertEqual(client.stored[PhiSyncEntity.settingsClientTagHash]?.ciphertext, foreign)
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
        let entity = PhiRemoteEntity(entityId: "srv-1", clientTagHash: PhiSyncEntity.settingsClientTagHash,
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

    /// A mismatch preserves the previous cursor and blocks ordinary retry and relaunch.
    func testNotMyBirthdayPreservesStateUntilExplicitReset() async throws {
        let key = SymmetricKey(size: .bits256)
        let client = FakePhiSyncClient()
        defaults.set("stale-birthday", forKey: PhiSyncEngine.storeBirthdayStateKey)
        defaults.set(Data("4".utf8), forKey: PhiSyncEngine.markerStateKey)
        client.getUpdatesErrorOnce = PhiSyncProtocolError.notMyBirthday
        let engine = makeEngine(client, key: key, now: 1_000)
        await engine.pullOnce()
        await engine.pullOnce()
        await makeEngine(client, key: key, now: 2_000).pullOnce()
        XCTAssertEqual(client.getUpdatesCalls.count, 1)
        XCTAssertTrue(engine.requiresReconfiguration)
        XCTAssertEqual(defaults.string(forKey: PhiSyncEngine.storeBirthdayStateKey), "stale-birthday")
        XCTAssertEqual(defaults.data(forKey: PhiSyncEngine.markerStateKey), Data("4".utf8))
        XCTAssertTrue(client.commits.isEmpty)
    }

    func testNotMyBirthdayKeepsThisDevicesSettingsHistory() async throws {
        let key = SymmetricKey(size: .bits256)
        let client = FakePhiSyncClient()
        client.seed(ciphertext: try ciphertext(settingEntity(settingKey, false, at: 1_000), key: key), version: 5)
        await makeEngine(client, key: key, now: 2_000).pullOnce()
        XCTAssertNotNil(defaults.object(forKey: PhiSyncEngine.hasAdoptedStateKey),
                        "precondition: the first pull adopted, so this device has settings history")

        // A local edit, then a round the server answers with NOT_MY_BIRTHDAY.
        defaults.set(true, forKey: settingKey)
        client.getUpdatesErrorOnce = PhiSyncProtocolError.notMyBirthday
        await makeEngine(client, key: key, now: 3_000).pullOnce()

        XCTAssertNotNil(defaults.object(forKey: PhiSyncEngine.hasAdoptedStateKey),
                        "a new store birthday is not an account switch")
        XCTAssertTrue(defaults.bool(forKey: settingKey),
                      "the mismatch must not overwrite local preferences")
        XCTAssertTrue(client.commits.isEmpty, "Publication waits for explicit reconfiguration")
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
        XCTAssertEqual(client.commits[0].clientTagHash, PhiSyncEntity.settingsClientTagHash)
        // M3-2: the wire `name` moved from the client into `PhiCommitEntry`. The settings
        // entity must keep sending "phi-settings" — a different value would change the row the
        // server persists and defeat its "did anything change" comparison.
        XCTAssertEqual(client.commits[0].name, PhiSyncEntity.clientTag)
        XCTAssertFalse(client.commits[0].deleted)
        XCTAssertEqual(client.commits[0].storeBirthday, "birthday-1")
        let committed = try decryptSetting(try XCTUnwrap(client.commits[0].ciphertext), key: key)
        XCTAssertEqual(committed.values[settingKey]?.boolValue, true)
        XCTAssertEqual(committed.values[settingKey]?.updatedAtMs, 2_000)
        // The server-assigned id and the new version are persisted for the next round.
        XCTAssertEqual(defaults.object(forKey: PhiSyncEngine.versionStateKey) as? NSNumber, NSNumber(value: client.stored[PhiSyncEntity.settingsClientTagHash]!.version))
    }

    func testEveryLocalPushPullsBeforeCommitting() async throws {
        let key = SymmetricKey(size: .bits256)
        let client = FakePhiSyncClient()
        client.seed(ciphertext: try ciphertext(settingEntity(settingKey, false, at: 1_000), key: key), version: 5)
        let clock = PhiSyncEngineSpaceTests.Clock()
        clock.nowMs = 2_000
        let engine = PhiSyncEngine(domainKeys: StubDomainKeys(key: key), client: client,
                                   defaults: defaults, deviceKeyId: "devA", pairingComplete: true, settings: registry(settingKey),
                                   now: { clock.read() })
        await engine.pullOnce()

        for value in [true, false] {
            clock.nowMs += 1_000
            defaults.set(value, forKey: settingKey)
            let start = client.callLog.count
            await engine.handleLocalDefaultsChange()
            XCTAssertEqual(Array(client.callLog.dropFirst(start)),
                           ["getUpdates.begin", "getUpdates.end", "commit"])
        }
    }

    func testEstablishedPushStopsWhenPreflightPullFails() async throws {
        let key = SymmetricKey(size: .bits256)
        let client = FakePhiSyncClient()
        client.seed(ciphertext: try ciphertext(settingEntity(settingKey, false, at: 1_000), key: key), version: 5)
        let engine = makeEngine(client, key: key, now: 2_000)
        await engine.pullOnce()
        defaults.set(true, forKey: settingKey)
        client.getUpdatesErrorOnce = URLError(.notConnectedToInternet)

        await engine.pushLocalSettings()

        XCTAssertTrue(client.commits.isEmpty)
        XCTAssertTrue(defaults.bool(forKey: settingKey), "The local edit must remain available for a later round")
        await engine.pushLocalSettings()
        XCTAssertEqual(client.commits.count, 1, "A later successful pull permits the pending edit")
    }

    func testPushAppliesNewerRemoteSettingsBeforeBuildingCommit() async throws {
        let key = SymmetricKey(size: .bits256)
        let client = FakePhiSyncClient()
        client.seed(ciphertext: try ciphertext(settingEntity(settingKey, false, at: 1_000), key: key), version: 5)
        let engine = makeEngine(client, key: key, now: 2_000)
        await engine.pullOnce()
        defaults.set(true, forKey: settingKey)
        client.reseed(tagHash: PhiSyncEntity.settingsClientTagHash,
                      ciphertext: try ciphertext(settingEntity(settingKey, false, at: 3_000), key: key), version: 6)

        await engine.pushLocalSettings()

        XCTAssertFalse(defaults.bool(forKey: settingKey))
        XCTAssertTrue(client.commits.isEmpty, "Preflight must resolve the stale edit before any commit reaches the server")
    }

    func testConflictRetryStopsWhenItsPullFails() async throws {
        let key = SymmetricKey(size: .bits256)
        let client = FakePhiSyncClient()
        client.seed(ciphertext: try ciphertext(settingEntity(settingKey, false, at: 1_000), key: key), version: 5)
        let engine = makeEngine(client, key: key, now: 2_000)
        await engine.pullOnce()
        defaults.set(true, forKey: settingKey)
        client.forcedConflicts = 1
        client.getUpdatesErrorAfterPages = (1, URLError(.notConnectedToInternet))
        let start = client.callLog.count

        await engine.pushLocalSettings()

        XCTAssertEqual(Array(client.callLog.dropFirst(start)),
                       ["getUpdates.begin", "getUpdates.end", "commit", "getUpdates.begin", "getUpdates.end"])
        XCTAssertEqual(client.commits.count, 1, "A failed conflict pull must not authorize another commit")
    }

    func testUnfinishedPullDoesNotPublishSettings() async throws {
        let key = SymmetricKey(size: .bits256)
        let client = FakePhiSyncClient()
        client.seed(ciphertext: try ciphertext(settingEntity(settingKey, false, at: 1_000), key: key), version: 5)
        let engine = makeEngine(client, key: key, now: 2_000)
        await engine.pullOnce()
        defaults.set(true, forKey: settingKey)
        client.pageBudgetExhaustsAfter = 100_000

        await engine.pushLocalSettings()
        engine.shutdown()

        XCTAssertTrue(client.commits.isEmpty, "Reaching the page budget is not a completed preflight")
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
        XCTAssertEqual(client.getUpdatesCalls.count, 3, "initial pull, push preflight, and conflict recovery")
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

    /// After INVALID_MESSAGE drops the cursor the next push is a create, and the account now
    /// refuses a create over the live row it still holds, naming that row. The settings path
    /// needs no id from the conflict — its recovery pull adopts the row and the retry is an
    /// update at the adopted version — but it must not loop, and it must keep the local edit.
    func testACreateRefusedByTheLiveRowAdoptsItThroughTheRecoveryPull() async throws {
        let key = SymmetricKey(size: .bits256)
        let client = FakePhiSyncClient()
        client.seed(ciphertext: try ciphertext(settingEntity(settingKey, false, at: 1_000), key: key),
                    version: 5)
        let engine = makeEngine(client, key: key, now: 2_000)
        await engine.pullOnce()

        // The rejection that wipes entity id, version and marker.
        defaults.set(true, forKey: settingKey)
        client.commitErrorOnce = PhiSyncProtocolError.commitRejected(.invalidMessage)
        await engine.pushLocalSettings()

        // One empty page for the next push's preflight pull, so the commit really goes out as a
        // create; the conflict recovery pull that follows it reads the seeded store again.
        client.conflictsOnLiveCreate = true
        client.scriptedPages = [FakePhiSyncClient.Page(entities: [], newMarker: Data("0".utf8),
                                                       changesRemaining: false)]
        await engine.pushLocalSettings()

        XCTAssertEqual(client.commits.count, 3,
                       "the rejected update, the refused create and one retry — no loop")
        XCTAssertNil(client.commits[1].entityId, "the second commit is a create")
        XCTAssertEqual(client.commits[1].baseVersion, 0, "and a create carries no base version")
        XCTAssertEqual(client.commits[2].entityId, "srv-seed", "the retry names the adopted row")
        XCTAssertEqual(client.commits[2].baseVersion, 5, "at the version the pull adopted")
        XCTAssertEqual(defaults.string(forKey: PhiSyncEngine.entityIdStateKey), "srv-seed")
        XCTAssertTrue(defaults.bool(forKey: settingKey), "the local edit survives the refusal")
    }

    /// INVALID_MESSAGE means the server has no row for the id this commit names (pgx.ErrNoRows
    /// on the update path, or a data_type mismatch). NOT_MY_BIRTHDAY never fires for it, and an
    /// incremental GetUpdates returns nothing, so without dropping the cursor the device would
    /// resend the same rejected id forever and never sync again.
    ///
    /// What goes is the *row identity* and the marker. The account did not change, so the
    /// store birthday and — load-bearing — `hasAdopted` stay: see
    /// `testALocalEditSurvivesAnInvalidMessageRejection`.
    func testCommitRejectedAsInvalidMessageDropsTheEntityCursor() async throws {
        let key = SymmetricKey(size: .bits256)
        let client = FakePhiSyncClient()
        client.seed(ciphertext: try ciphertext(settingEntity(settingKey, false, at: 1_000), key: key), version: 5)
        let engine = makeEngine(client, key: key, now: 2_000)
        await engine.pullOnce()

        defaults.set(true, forKey: settingKey)
        client.commitErrorOnce = PhiSyncProtocolError.commitRejected(.invalidMessage)
        await engine.pushLocalSettings()

        XCTAssertEqual(client.commits.count, 1)
        for stateKey in [PhiSyncEngine.entityIdStateKey, PhiSyncEngine.versionStateKey,
                         PhiSyncEngine.lastEntityStateKey, PhiSyncEngine.markerStateKey] {
            XCTAssertNil(defaults.object(forKey: stateKey), "\(stateKey) survived INVALID_MESSAGE")
        }
        XCTAssertNotNil(defaults.object(forKey: PhiSyncEngine.hasAdoptedStateKey),
                        "this device's settings history is not the server's to invalidate")
        XCTAssertEqual(defaults.string(forKey: PhiSyncEngine.storeBirthdayStateKey), "birthday-1",
                       "the account row — and its store birthday — is untouched by INVALID_MESSAGE")
    }

    /// The regression the split above exists for. A rejected commit used to clear `hasAdopted`
    /// along with the cursor, which re-armed the wholesale adopt: the next pull replaced the
    /// edit that had just been snapshotted with a peer's older value and — because `apply` also
    /// writes the remote timestamp into the key's sidecar — the edit was never re-pushed
    /// either. It has to be merged and published instead.
    func testALocalEditSurvivesAnInvalidMessageRejection() async throws {
        let key = SymmetricKey(size: .bits256)
        let client = FakePhiSyncClient()
        client.seed(ciphertext: try ciphertext(settingEntity(settingKey, false, at: 1_000), key: key), version: 5)
        let engine = makeEngine(client, key: key, now: 2_000)
        await engine.pullOnce()
        XCTAssertFalse(defaults.bool(forKey: settingKey), "precondition: the account's value is false")

        // The user flips the setting; the commit names a row the server no longer has.
        defaults.set(true, forKey: settingKey)
        client.commitErrorOnce = PhiSyncProtocolError.commitRejected(.invalidMessage)
        await engine.pushLocalSettings()
        XCTAssertEqual(defaults.object(forKey: SyncableSettings.timestampKey(for: settingKey)) as? NSNumber,
                       NSNumber(value: Int64(2_000)),
                       "precondition: the refused push still stamped the edit at `now`")

        // A peer has re-created the account's settings under the same client tag, still
        // carrying the old value, and the next pull finds it.
        client.seed(ciphertext: try ciphertext(settingEntity(settingKey, false, at: 1_000), key: key),
                    version: 9, entityId: "srv-new")
        await makeEngine(client, key: key, now: 4_000).pullOnce()

        XCTAssertTrue(defaults.bool(forKey: settingKey),
                      "the rejected commit must not cost this device the edit it was carrying")
        XCTAssertEqual(client.commits.count, 2, "the surviving edit is published to the new row")
        let committed = try decryptSetting(try XCTUnwrap(client.commits[1].ciphertext), key: key)
        XCTAssertEqual(committed.values[settingKey]?.boolValue, true)
        XCTAssertEqual(committed.values[settingKey]?.updatedAtMs, 2_000,
                       "the edit keeps the timestamp it was stamped with, not a fresh one")
    }

    /// A locked key layer must abort the round quietly, without committing anything.
    func testLockedDomainKeyAbortsTheRound() async throws {
        let client = FakePhiSyncClient()
        let keys = StubDomainKeys(key: SymmetricKey(size: .bits256))
        keys.error = ProfileKeyManagerError.notUnlocked
        let engine = PhiSyncEngine(domainKeys: keys, client: client, defaults: defaults,
                                   deviceKeyId: "devA", pairingComplete: true, settings: registry(settingKey), now: { 1_000 })

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
                       ["getUpdates.end", "getUpdates.end", "commit", "getUpdates.end"],
                       "the commit lands after the parked pull finished its round, not during it")
    }

    // MARK: - State

    /// The account-scope reset drops every account-scoped cursor, so account A's marker and
    /// version can never be replayed against account B. The app performs that wipe from
    /// outside, in `PhiChromiumCoordinator.resetPhiSyncCursorIfAccountChanged`; this pins the
    /// engine-side helper of the same shape, which is what the recovery paths are measured
    /// against (`clearRemoteCursor()` / `resetForNewStoreBirthday()` keep `hasAdopted`).
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

    // MARK: - Shutdown

    /// Sign-out reaches the engine while a round is parked in the network. Dropping the
    /// engine reference and cancelling the coordinator's timer/observer/debounce only stops
    /// *new* rounds — this one is already on `roundQueue`, keeps the engine alive through its
    /// own task, and resumes long after sign-out. It must write nothing: not the cursor, not
    /// the settings it decrypted with the signed-out account's domain key, and no commit.
    func testARoundParkedInTheNetworkWritesNothingAfterShutdown() async throws {
        let key = SymmetricKey(size: .bits256)
        let client = FakePhiSyncClient()
        client.seed(ciphertext: try ciphertext(settingEntity(settingKey, true, at: 999), key: key), version: 5)

        let arrived = Gate()
        let release = Gate()
        client.arrivedInGetUpdates = arrived
        client.getUpdatesGate = release

        let engine = makeEngine(client, key: key, now: 1_000)
        let parked = Task { await engine.pullOnce() }
        await arrived.wait()                     // the pull is now suspended inside getUpdates

        engine.shutdown()                        // synchronous, exactly as `stopPhiSync()` calls it
        await release.open()
        await parked.value

        for stateKey in PhiSyncEngine.stateKeys {
            XCTAssertNil(defaults.object(forKey: stateKey), "\(stateKey) was written after shutdown")
        }
        XCTAssertNil(defaults.object(forKey: settingKey), "remote settings were applied after shutdown")
        XCTAssertTrue(client.commits.isEmpty)
    }

    func testEnrollmentWithdrawalFencesAParkedRoundEvenAfterReenable() async throws {
        let key = SymmetricKey(size: .bits256)
        let client = FakePhiSyncClient()
        client.seed(ciphertext: try ciphertext(settingEntity(settingKey, true, at: 999), key: key), version: 5)

        let arrived = Gate()
        let release = Gate()
        client.arrivedInGetUpdates = arrived
        client.getUpdatesGate = release

        let engine = makeEngine(client, key: key, now: 1_000)
        let parked = Task { await engine.pullOnce() }
        await arrived.wait()                     // the pull is now suspended inside getUpdates

        engine.suspendForPairing()
        await engine.enableAfterPairing()
        await release.open()
        await parked.value

        for stateKey in PhiSyncEngine.stateKeys {
            XCTAssertNil(defaults.object(forKey: stateKey), "\(stateKey) was written after pairing eligibility changed")
        }
        XCTAssertNil(defaults.object(forKey: settingKey), "remote settings were applied after pairing eligibility changed")
        XCTAssertTrue(client.commits.isEmpty)
    }

    /// The other half of the same window: a debounced local change chained behind the parked
    /// pull. It runs when the pull finally unwinds, i.e. after sign-out, and must not commit
    /// the signed-out account's snapshot — the bearer token the client carries by then belongs
    /// to whoever signed in next.
    func testShutdownStopsRoundsQueuedBehindTheParkedOne() async throws {
        let key = SymmetricKey(size: .bits256)
        let client = FakePhiSyncClient()
        client.seed(ciphertext: try ciphertext(settingEntity(settingKey, false, at: 1_000), key: key), version: 5)
        // A first round establishes the cursor and the baseline, so the queued push has
        // something to publish against and would otherwise really commit.
        await makeEngine(client, key: key, now: 1_000).pullOnce()
        let cursorBefore = PhiSyncEngine.stateKeys.map { defaults.object(forKey: $0) as? NSObject }

        let arrived = Gate()
        let release = Gate()
        client.arrivedInGetUpdates = arrived
        client.getUpdatesGate = release

        let engine = makeEngine(client, key: key, now: 3_000)
        let parked = Task { await engine.pullOnce() }
        await arrived.wait()

        defaults.set(true, forKey: settingKey)   // a user edit lands mid-round
        let queued = Task { await engine.handleLocalDefaultsChange() }
        for _ in 0..<32 { await Task.yield() }

        engine.shutdown()
        await release.open()
        await parked.value
        await queued.value

        XCTAssertTrue(client.commits.isEmpty, "a round queued before sign-out still published")
        let cursorAfter = PhiSyncEngine.stateKeys.map { defaults.object(forKey: $0) as? NSObject }
        XCTAssertEqual(cursorBefore, cursorAfter, "the cursor moved after shutdown")
    }

    /// The account-isolation invariant end to end, in the shape the review found the hole in:
    /// A's pull is parked, the user signs out and in as B (`stopPhiSync()` shuts A down,
    /// `resetPhiSyncCursorIfAccountChanged` wipes the cursor, a second engine mounts over the
    /// same `UserDefaults`), and only then does A's round resume. B's cursor and B's settings
    /// must survive untouched.
    func testADyingRoundCannotOverwriteTheNextAccountsCursor() async throws {
        let keyA = SymmetricKey(size: .bits256)
        let clientA = FakePhiSyncClient()
        clientA.storeBirthday = "birthday-a"
        clientA.seed(ciphertext: try ciphertext(settingEntity(settingKey, true, at: 9_000), key: keyA),
                     version: 5, entityId: "srv-a")
        let arrived = Gate()
        let release = Gate()
        clientA.arrivedInGetUpdates = arrived
        clientA.getUpdatesGate = release

        PhiChromiumCoordinator.resetPhiSyncCursorIfAccountChanged(accountId: "auth0|alice", defaults: defaults)
        let engineA = makeEngine(clientA, key: keyA, now: 1_000)
        let parked = Task { await engineA.pullOnce() }
        await arrived.wait()

        // Sign out, then sign in as account B.
        engineA.shutdown()
        PhiChromiumCoordinator.resetPhiSyncCursorIfAccountChanged(accountId: "auth0|bob", defaults: defaults)
        let keyB = SymmetricKey(size: .bits256)
        let clientB = FakePhiSyncClient()
        clientB.storeBirthday = "birthday-b"
        clientB.seed(ciphertext: try ciphertext(settingEntity(settingKey, false, at: 8_000), key: keyB),
                     version: 11, entityId: "srv-b")
        await makeEngine(clientB, key: keyB, now: 2_000).pullOnce()

        // A's round only now comes back from the network.
        await release.open()
        await parked.value

        XCTAssertEqual(defaults.string(forKey: PhiSyncEngine.entityIdStateKey), "srv-b")
        XCTAssertEqual(defaults.object(forKey: PhiSyncEngine.versionStateKey) as? NSNumber,
                       NSNumber(value: Int64(11)))
        XCTAssertEqual(defaults.string(forKey: PhiSyncEngine.storeBirthdayStateKey), "birthday-b")
        XCTAssertFalse(defaults.bool(forKey: settingKey), "account A's settings landed on account B")
        XCTAssertTrue(clientA.commits.isEmpty, "the dying round committed against the previous account")
    }

    /// The narrower window the review named: `shutdown()` is concurrent with the round, so it
    /// can land *after* `apply` has passed its entry guard and before the settings are written.
    /// The settings write makes its own check for exactly that reason — the same standard the
    /// cursor writes already held — so the signed-out account's decrypted value is not applied.
    ///
    /// `now()` is the seam: the engine calls it while snapshotting the local side of the merge,
    /// which is inside the stretch the entry guard cannot speak for. Shutting down from in
    /// there reproduces the interleaving deterministically instead of racing two threads.
    func testShutdownAfterTheApplyGuardStillStopsTheSettingsWrite() async throws {
        let key = SymmetricKey(size: .bits256)
        let client = FakePhiSyncClient()
        client.seed(ciphertext: try ciphertext(settingEntity(settingKey, true, at: 9_000), key: key), version: 5)
        // Settings history already exists, so the pull merges (and therefore snapshots) rather
        // than adopting the remote entity wholesale without ever calling `now()`.
        defaults.set(true, forKey: PhiSyncEngine.hasAdoptedStateKey)
        defaults.set(false, forKey: settingKey)

        let holder = EngineHolder()
        let engine = PhiSyncEngine(domainKeys: StubDomainKeys(key: key),
                                   client: client,
                                   defaults: defaults,
                                   deviceKeyId: "devA", pairingComplete: true,
                                   settings: registry(settingKey),
                                   now: { [holder] in holder.engine?.shutdown(); return 1_000 })
        holder.engine = engine

        await engine.pullOnce()

        XCTAssertFalse(defaults.bool(forKey: settingKey),
                       "the remote value was applied by a round retired mid-apply")
        XCTAssertTrue(client.commits.isEmpty, "the trailing push ran after shutdown")
    }
}

// MARK: - C2 / R2.1: the hybrid logical clock is account-scoped cursor state

extension PhiSyncEngineTests {

    /// `hlcMax` goes through `writeState`, which carries the retirement guard, for the same
    /// reason the rest of `stateKeys` does: a retired engine still holds the signed-out
    /// account's `UserDefaults`, and advancing logical time there would hand the account
    /// mounted next a clock it never earned.
    func testARetiredEngineDoesNotWriteTheHybridClock() async throws {
        let key = SymmetricKey(size: .bits256)
        let client = FakePhiSyncClient()
        client.seed(ciphertext: try ciphertext(settingEntity(settingKey, true, at: 9_000_000),
                                               key: key),
                    version: 5)
        let engine = makeEngine(client, key: key, now: 1_000)

        engine.shutdown()                        // synchronous, exactly as `stopPhiSync()` calls it
        await engine.pullOnce()
        await engine.pushLocalSettings()

        XCTAssertNil(defaults.object(forKey: PhiSyncEngine.hlcMaxStateKey),
                     "a retired engine must leave the next account's logical time alone")
    }

    /// The other half: a live engine does persist it, so the case above is not passing merely
    /// because nothing ever writes the key.
    func testALiveEngineRecordsTheHybridClockItLandedFrom() async throws {
        let key = SymmetricKey(size: .bits256)
        let client = FakePhiSyncClient()
        client.seed(ciphertext: try ciphertext(settingEntity(settingKey, true, at: 9_000_000),
                                               key: key),
                    version: 5)

        await makeEngine(client, key: key, now: 1_000).pullOnce()

        let stored = (defaults.object(forKey: PhiSyncEngine.hlcMaxStateKey) as? NSNumber)?.int64Value
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(stored), 9_000_000)
    }
}

// MARK: - AM-2: the wall-clock offset learned from the server's `Date` header

extension PhiSyncEngineTests {

    private func storedOffset() -> Int64? {
        (defaults.object(forKey: PhiSyncEngine.wallClockOffsetStateKey) as? NSNumber)?.int64Value
    }

    /// A pull measures the offset and persists it, so an OFFLINE edit made before the next pull
    /// is still stamped through a corrected clock. Without persistence AM-2 would cover only the
    /// device that is online at the moment it edits, which is the case that needs it least.
    func testAPullPersistsAnOffsetBeyondTheThreshold() async throws {
        let key = SymmetricKey(size: .bits256)
        let client = FakePhiSyncClient()
        client.seed(ciphertext: try ciphertext(settingEntity(settingKey, true, at: 999), key: key),
                    version: 5)
        // The device believes it is 1_000; the server says it is six hours later.
        client.lastServerDateMs = 1_000 + 6 * 3_600_000

        await makeEngine(client, key: key, now: 1_000).pullOnce()

        XCTAssertEqual(storedOffset(), 6 * 3_600_000)
    }

    /// Ordinary skew persists nothing, so the key stays absent on every healthy device and a
    /// correction that later drops back under the threshold removes it rather than freezing a
    /// stale value in place.
    func testAnOffsetWithinTheThresholdPersistsNothing() async throws {
        let key = SymmetricKey(size: .bits256)
        let client = FakePhiSyncClient()
        client.seed(ciphertext: try ciphertext(settingEntity(settingKey, true, at: 999), key: key),
                    version: 5)
        client.lastServerDateMs = 1_000 + 30_000      // half a minute

        await makeEngine(client, key: key, now: 1_000).pullOnce()

        XCTAssertNil(storedOffset())
    }

    /// The offset is in `stateKeys`, so an account switch wipes it with everything else. It is a
    /// per-DEVICE quantity, so that is coarser than strictly necessary; it is also free, because
    /// the first response of the next round re-learns it before any commit can be sent.
    func testResettingAccountStateWipesTheOffset() async throws {
        let key = SymmetricKey(size: .bits256)
        let client = FakePhiSyncClient()
        client.seed(ciphertext: try ciphertext(settingEntity(settingKey, true, at: 999), key: key),
                    version: 5)
        client.lastServerDateMs = 1_000 + 6 * 3_600_000
        let engine = makeEngine(client, key: key, now: 1_000)
        await engine.pullOnce()
        XCTAssertNotNil(storedOffset(), "precondition: the offset was learned")

        await engine.resetSyncState()

        XCTAssertNil(storedOffset())
        XCTAssertTrue(PhiSyncEngine.stateKeys.contains(PhiSyncEngine.wallClockOffsetStateKey),
                      "the key must be in stateKeys, which is what the coordinator wipes")
    }

    /// A retired engine measures nothing: it still holds the signed-out account's `UserDefaults`,
    /// and `observeServerDate` goes through `writeState` for exactly the reason `hlcMax` does.
    func testARetiredEngineDoesNotRecordAnOffset() async throws {
        let key = SymmetricKey(size: .bits256)
        let client = FakePhiSyncClient()
        client.seed(ciphertext: try ciphertext(settingEntity(settingKey, true, at: 999), key: key),
                    version: 5)
        client.lastServerDateMs = 1_000 + 6 * 3_600_000
        let engine = makeEngine(client, key: key, now: 1_000)

        engine.shutdown()
        await engine.pullOnce()

        XCTAssertNil(storedOffset())
    }
}

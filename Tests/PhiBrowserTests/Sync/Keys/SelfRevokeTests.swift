import CryptoKit
import Security
import XCTest
@testable import Phi

@MainActor
final class SelfRevokeTests: XCTestCase {
    typealias FakeAPI = AccountKeyManagerTests.FakeAPI
    typealias FakeDeviceKeyProvider = AccountKeyManagerTests.FakeDeviceKeyProvider
    typealias MemoryMappingStore = ProfileKeyManagerTests.MemoryMappingStore

    /// Records the ORDER of every teardown step: retirement must strictly precede
    /// every piece of cleanup, or an in-flight round writes the account's whole
    /// Space set and settings back onto a machine that just left the account.
    final class Ledger { var steps: [String] = [] }

    final class RecordingDeviceKeyStore: DeviceKeyRotating {
        let ledger: Ledger
        private(set) var rotations = 0
        var rotateError: Error?
        init(ledger: Ledger) { self.ledger = ledger }
        func rotateForCurrentAccount() throws {
            rotations += 1
            ledger.steps.append("rotate")
            if let rotateError { throw rotateError }
        }
    }

    /// ownedItemStores defaults to empty and markerStore to nil, matching production:
    /// this controller has no owned-item sections or marker file. Preserve the three existing cases.
    private func makeController(api: FakeAPI, ledger: Ledger, store: MemoryMappingStore,
                                rotator: RecordingDeviceKeyStore,
                                spaceStore: PhiSpaceSyncStateStore,
                                defaults: UserDefaults,
                                ownedItemStores: [any PhiOwnedItemStateStore] = [],
                                markerStore: (any PhiSyncMarkerStore)? = nil,
                                localResetMarker: SyncPairingLocalResetMarkerStore? = nil,
                                localResetAccess: PhiLocalDataReset.LocalAccess? = nil,
                                isPairingComplete: @escaping @MainActor () -> Bool = { ProfilePairingGate.shared.isPaired },
                                profileDeletionIntents: @escaping @MainActor () -> (any PhiProfileDeletionIntentStore)? = {
                                    PhiSpaceSyncState.shared.profileDeletionIntentStore
                                }) async throws -> SyncKeyController {
        let mgr = AccountKeyManager(api: api, deviceKeyProvider: FakeDeviceKeyProvider())
        _ = try await mgr.bootstrap()
        let pkm = ProfileKeyManager(api: api, keyManager: mgr, mappingStore: store)
        let approvals = DeviceApprovalService(api: api, keyManager: mgr,
                                              deviceKeyProvider: FakeDeviceKeyProvider())
        let controller = SyncKeyController(
            manager: mgr, approvals: approvals, profileKeys: pkm,
            localProfilesProvider: { [] }, notifyChromium: {},
            isPairingComplete: isPairingComplete,
            retirePhiSync: { _ in ledger.steps.append("retire") },
            invalidateEnrollment: { ledger.steps.append("unpair") },
            deviceKeyRotator: rotator,
            engineDefaults: defaults,
            spaceStateStore: spaceStore,
            ownedItemStores: ownedItemStores,
            markerStore: markerStore,
            localResetMarker: localResetMarker,
            localResetAccess: localResetAccess,
            profileDeletionIntents: profileDeletionIntents)
        return controller
    }

    func testRetirementStrictlyPrecedesEveryPieceOfCleanup() async throws {
        let api = FakeAPI()
        let ledger = Ledger()
        let store = MemoryMappingStore()
        store.map = ["Default": "uuid-a"]
        let rotator = RecordingDeviceKeyStore(ledger: ledger)
        let spaceStore = PhiSyncEngineSpaceTests.MemorySpaceStore()
        spaceStore.table.cursors["u1"] = PhiSpaceCursor()
        let suite = "SelfRevokeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        for key in PhiSyncEngine.stateKeys { defaults.set("x", forKey: key) }
        defaults.set("acct", forKey: PhiChromiumCoordinator.phiSyncCursorOwnerKey)

        let controller = try await makeController(api: api, ledger: ledger, store: store,
                                                  rotator: rotator, spaceStore: spaceStore,
                                                  defaults: defaults)
        try await controller.removeThisDeviceFromSync()

        XCTAssertEqual(ledger.steps.first, "retire")
        XCTAssertEqual(rotator.rotations, 1)
        XCTAssertEqual(api.revokedDeviceKeyIds.count, 1)
        XCTAssertNil(controller.manager.currentARK)
        XCTAssertTrue(store.map.isEmpty)
        XCTAssertTrue(PhiSyncEngine.stateKeys.allSatisfy { defaults.object(forKey: $0) == nil })
        XCTAssertEqual(defaults.string(forKey: PhiChromiumCoordinator.phiSyncCursorOwnerKey), "acct",
                       "the cursor OWNER is not a cursor; dropping it would fake an account switch")
        XCTAssertEqual(spaceStore.table, PhiSpaceSyncTable())
        XCTAssertFalse(controller.needsPairing)
        XCTAssertTrue(ledger.steps.contains("unpair"))
    }

    func testALastDeviceRejectionChangesNothingLocally() async throws {
        let api = FakeAPI()
        api.revokeError = KeyAPIError.lastActiveDevice
        let ledger = Ledger()
        let store = MemoryMappingStore()
        store.map = ["Default": "uuid-a"]
        let rotator = RecordingDeviceKeyStore(ledger: ledger)
        let spaceStore = PhiSyncEngineSpaceTests.MemorySpaceStore()
        let suite = "SelfRevokeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let controller = try await makeController(api: api, ledger: ledger, store: store,
                                                  rotator: rotator, spaceStore: spaceStore,
                                                  defaults: defaults)
        do {
            try await controller.removeThisDeviceFromSync()
            XCTFail("expected lastActiveDevice")
        } catch KeyAPIError.lastActiveDevice {}
        XCTAssertTrue(ledger.steps.isEmpty, "nothing is torn down when the server refuses")
        XCTAssertEqual(rotator.rotations, 0)
        XCTAssertEqual(store.map, ["Default": "uuid-a"])
        XCTAssertNotNil(controller.manager.currentARK)
    }

    /// Partial cleanup remains blocked and can be retried without revoking twice.
    func testAFailedKeyRotationKeepsTheJournalForExplicitRetry() async throws {
        let api = FakeAPI()
        let ledger = Ledger()
        let store = MemoryMappingStore()
        store.map = ["Default": "uuid-a"]
        let rotator = RecordingDeviceKeyStore(ledger: ledger)
        rotator.rotateError = DeviceKeyStoreError.keychainFailure(errSecInteractionNotAllowed)
        let spaceStore = PhiSyncEngineSpaceTests.MemorySpaceStore()
        spaceStore.table.cursors["u1"] = PhiSpaceCursor()
        let suite = "SelfRevokeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        for key in PhiSyncEngine.stateKeys { defaults.set("x", forKey: key) }

        let marker = MemoryMarkerStore()
        let controller = try await makeController(api: api, ledger: ledger, store: store,
                                                  rotator: rotator, spaceStore: spaceStore,
                                                  defaults: defaults, markerStore: marker)
        do {
            try await controller.removeThisDeviceFromSync()
            XCTFail("Expected the Keychain failure")
        } catch DeviceKeyStoreError.keychainFailure {}
        XCTAssertEqual(marker.file.requiresReconfiguration, true)
        XCTAssertEqual(marker.file.removalPending, true)
        rotator.rotateError = nil
        try await controller.reconfigureSync()

        XCTAssertEqual(rotator.rotations, 2)
        XCTAssertEqual(ledger.steps.first, "retire")
        XCTAssertNil(controller.manager.currentARK)
        XCTAssertTrue(store.map.isEmpty)
        XCTAssertTrue(PhiSyncEngine.stateKeys.allSatisfy { defaults.object(forKey: $0) == nil })
        XCTAssertEqual(spaceStore.table, PhiSpaceSyncTable())
        XCTAssertFalse(controller.needsPairing)
    }

    /// CASE 3.2 (M3-4a §4.4): self-revoke step 4 deletes marker.json alongside both
    /// cursor tables, rather than saving an empty table. Step 1 precedes all cleanup;
    /// step 5 also erases both legacy keys.
    ///
    /// Deleting cursor tables but retaining the marker reproduces §4.4's destructive
    /// failure: rejoin sees a marker beyond account history and replays no entities,
    /// so identities are not reclaimed. Empty cursors then make §5.7's diff treat the
    /// entire table as locally deleted and tombstone every device's bookmarks, pins, and rules.
    func testSelfRevocationDeletesTheMarkerFileAlongsideBothCursorTables() async throws {
        let api = FakeAPI()
        let ledger = Ledger()
        let store = MemoryMappingStore()
        store.map = ["Default": "uuid-a"]
        let rotator = RecordingDeviceKeyStore(ledger: ledger)
        let spaceStore = PhiSyncEngineSpaceTests.MemorySpaceStore()
        let markerStore = MemoryMarkerStore(
            file: PhiSyncMarkerFile(marker: Data("m".utf8), storeBirthday: "B"))
        // Both cursor tables are nonempty.
        var cursors = PhiOwnedItemTable()
        cursors.cursors["b1"] = PhiOwnedItemCursor()
        let bookmarkStore = MemoryOwnedItemStore(table: cursors)
        let pinStore = MemoryOwnedItemStore(table: cursors)
        let suite = "SelfRevokeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        for key in PhiSyncEngine.stateKeys { defaults.set("x", forKey: key) }
        // Simulate failed migration persistence, leaving both legacy keys for step 5 to erase (ruling 3).
        for key in PhiSyncEngine.legacyMarkerStateKeys { defaults.set("x", forKey: key) }

        let controller = try await makeController(api: api, ledger: ledger, store: store,
                                                  rotator: rotator, spaceStore: spaceStore,
                                                  defaults: defaults,
                                                  ownedItemStores: [bookmarkStore, pinStore],
                                                  markerStore: markerStore)
        try await controller.removeThisDeviceFromSync()

        XCTAssertTrue(markerStore.deleted, "marker.json is deleted")
        XCTAssertTrue(bookmarkStore.deleted)
        XCTAssertTrue(pinStore.deleted)
        XCTAssertEqual(ledger.steps.first, "retire", "Step 1 precedes all cleanup")
        XCTAssertEqual(markerStore.saves.first?.requiresReconfiguration, true, "Journal precedes cleanup")
        XCTAssertTrue(PhiSyncEngine.stateKeys.allSatisfy { defaults.object(forKey: $0) == nil })
        XCTAssertTrue(PhiSyncEngine.legacyMarkerStateKeys.allSatisfy { defaults.object(forKey: $0) == nil },
                      "Step 5 also erases migration leftovers")
    }

    // MARK: - Pairing local data reset (docs/sync.md, "Replacing this Mac's data at pairing")

    /// Device removal invalidates the enrollment a pairing reset belonged to, so it drops the
    /// resume marker with it.
    func testSelfRevocationClearsThePairingResetMarker() async throws {
        let api = FakeAPI()
        let ledger = Ledger()
        let slot = SyncPairingLocalResetMarkerTests.Slot()
        try slot.store.save(SyncPairingLocalResetMarker(deviceKeyID: "d", deleteProfileIds: [], startedAtMs: 1))
        let suite = "SelfRevokeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let controller = try await makeController(api: api, ledger: ledger, store: MemoryMappingStore(),
                                                  rotator: RecordingDeviceKeyStore(ledger: ledger),
                                                  spaceStore: PhiSyncEngineSpaceTests.MemorySpaceStore(),
                                                  defaults: defaults, localResetMarker: slot.store)
        try await controller.removeThisDeviceFromSync()

        XCTAssertNil(slot.data)
    }

    /// The confirmed cleanup keeps its journal when the marker cannot be removed, so a retry
    /// finishes the job instead of leaving a resumable reset behind a new enrollment.
    func testAFailedMarkerRemovalKeepsTheCleanupJournal() async throws {
        let api = FakeAPI()
        let ledger = Ledger()
        let slot = SyncPairingLocalResetMarkerTests.Slot()
        try slot.store.save(SyncPairingLocalResetMarker(deviceKeyID: "d", deleteProfileIds: [], startedAtMs: 1))
        slot.failWrites = true
        let marker = MemoryMarkerStore()
        let suite = "SelfRevokeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let controller = try await makeController(api: api, ledger: ledger, store: MemoryMappingStore(),
                                                  rotator: RecordingDeviceKeyStore(ledger: ledger),
                                                  spaceStore: PhiSyncEngineSpaceTests.MemorySpaceStore(),
                                                  defaults: defaults, markerStore: marker,
                                                  localResetMarker: slot.store)
        do {
            try await controller.removeThisDeviceFromSync()
            XCTFail("expected the cleanup to fail")
        } catch NativeSyncResetError.cleanupFailed {}
        XCTAssertEqual(marker.file.requiresReconfiguration, true)
        slot.failWrites = false
        try await controller.reconfigureSync()
        XCTAssertNil(slot.data)
    }

    final class EmptyIntentStore: PhiProfileDeletionIntentStore {
        func load() -> [String: String] { [:] }
        func save(_ intents: [String: String]) -> Bool { true }
    }

    /// Local access that records whether the reset touched anything.
    @MainActor private final class TouchRecorder {
        var touched = false
        func access() -> PhiLocalDataReset.LocalAccess {
            let defaultRow = PhiLocalDataReset.SpaceRow(spaceId: LocalStore.defaultSpaceId,
                                                        profileId: LocalStore.defaultProfileId)
            return PhiLocalDataReset.LocalAccess(
                counts: { PhiDataCounts(bookmarks: 1) },
                userSpaces: { [defaultRow] },
                agentSpaces: { [] },
                chromiumProfileIds: { [LocalStore.defaultProfileId] },
                userAssignableProfileIds: { [LocalStore.defaultProfileId] },
                storedProfileIds: { [LocalStore.defaultProfileId] },
                isImporting: { _ in false },
                hasRunningAgentTask: { _, _ in false },
                setDefaultSpaceRole: { self.touched = true; return true },
                recreateDefaultSpace: { _ in self.touched = true },
                rebindDefaultSpace: { _ in self.touched = true; return .rebound },
                defaultSpaceWindowProfileIds: { [] },
                wipeOwnedItems: { self.touched = true },
                deleteSpace: { _ in self.touched = true; return .deleted },
                profilesWithLiveWindows: { _ in [] },
                isProfileInUse: { _ in false },
                deleteProfile: { _ in self.touched = true },
                removeProfileRows: { _ in self.touched = true })
        }
    }

    private func assertResetRefused(_ expected: PhiLocalDataResetError, spaceStore: PhiSyncEngineSpaceTests.MemorySpaceStore,
                                    intents: @escaping @MainActor () -> (any PhiProfileDeletionIntentStore)?,
                                    file: StaticString = #filePath, line: UInt = #line) async throws {
        let api = FakeAPI()
        let ledger = Ledger()
        let suite = "SelfRevokeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let recorder = TouchRecorder()
        let controller = try await makeController(api: api, ledger: ledger, store: MemoryMappingStore(),
                                                  rotator: RecordingDeviceKeyStore(ledger: ledger),
                                                  spaceStore: spaceStore, defaults: defaults,
                                                  markerStore: MemoryMarkerStore(), localResetAccess: recorder.access(),
                                                  isPairingComplete: { false }, profileDeletionIntents: intents)
        let reset = try XCTUnwrap(controller.localDataReset(), file: file, line: line)
        do {
            try await reset.clear(LocalResetRequest())
            XCTFail("expected the refusal", file: file, line: line)
        } catch let error as PhiLocalDataResetError {
            XCTAssertEqual(error, expected, file: file, line: line)
        }
        XCTAssertFalse(recorder.touched, file: file, line: line)
    }

    /// The controller wires the reset's no-history precondition to the real stores: one Space
    /// cursor with an account entity is enough to refuse, before any local data is touched.
    func testThePairingResetRefusesWhileSyncHistoryExists() async throws {
        let api = FakeAPI()
        let ledger = Ledger()
        let suite = "SelfRevokeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let unwired = try await makeController(api: api, ledger: ledger, store: MemoryMappingStore(),
                                               rotator: RecordingDeviceKeyStore(ledger: ledger),
                                               spaceStore: PhiSyncEngineSpaceTests.MemorySpaceStore(), defaults: defaults,
                                               localResetAccess: TouchRecorder().access())
        XCTAssertNil(unwired.localDataReset(), "without the marker store the history cannot be proven absent")

        let spaceStore = PhiSyncEngineSpaceTests.MemorySpaceStore()
        var cursor = PhiSpaceCursor()
        cursor.entityId = "entity-1"
        spaceStore.table.cursors["uuid-1"] = cursor
        try await assertResetRefused(.syncHistoryPresent(.spaceCursor), spaceStore: spaceStore,
                                     intents: { EmptyIntentStore() })
    }

    /// A Profile deletion journal that cannot be read counts as history: the reset fails closed.
    func testThePairingResetRefusesWithoutAReadableDeletionJournal() async throws {
        try await assertResetRefused(.syncHistoryPresent(.profileDeletionJournal),
                                     spaceStore: PhiSyncEngineSpaceTests.MemorySpaceStore(), intents: { nil })
    }
}

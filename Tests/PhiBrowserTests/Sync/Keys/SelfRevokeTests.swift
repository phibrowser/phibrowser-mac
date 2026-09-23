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
                                markerStore: (any PhiSyncMarkerStore)? = nil) async throws -> SyncKeyController {
        let mgr = AccountKeyManager(api: api, deviceKeyProvider: FakeDeviceKeyProvider())
        _ = try await mgr.bootstrap()
        let pkm = ProfileKeyManager(api: api, keyManager: mgr, mappingStore: store)
        let approvals = DeviceApprovalService(api: api, keyManager: mgr,
                                              deviceKeyProvider: FakeDeviceKeyProvider())
        let controller = SyncKeyController(
            manager: mgr, approvals: approvals, profileKeys: pkm,
            localProfilesProvider: { [] }, notifyChromium: {},
            retirePhiSync: { _ in ledger.steps.append("retire") },
            invalidateEnrollment: { ledger.steps.append("unpair") },
            deviceKeyRotator: rotator,
            engineDefaults: defaults,
            spaceStateStore: spaceStore,
            ownedItemStores: ownedItemStores,
            markerStore: markerStore)
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
}

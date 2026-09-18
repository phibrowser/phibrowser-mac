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

    /// `ownedItemStores` / `markerStore` 默认为空 / nil，与生产 `init` 的默认值同义——「这个
    /// controller 没有归属项段 / 没有 marker 文件」；既有三条用例一字不改。
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
            retirePhiSync: { ledger.steps.append("retire") },
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
        ProfilePairingGate.staticPendingOverride = true
        defer { ProfilePairingGate.staticPendingOverride = nil }

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
        XCTAssertEqual(ProfilePairingGate.joinPairingPending, false)
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
        ProfilePairingGate.staticPendingOverride = true
        defer { ProfilePairingGate.staticPendingOverride = nil }

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

    /// A Keychain that refuses the rotation (locked, or the item denied) must not
    /// abort the teardown: the server side is already revoked, so stopping here
    /// would strand the ARK, the mappings and the whole Space table on a machine
    /// that has left the account. It is logged rather than thrown, never swallowed
    /// by a `try?`.
    func testAFailedKeyRotationDoesNotAbortTheRestOfTheCleanup() async throws {
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
        ProfilePairingGate.staticPendingOverride = true
        defer { ProfilePairingGate.staticPendingOverride = nil }

        let controller = try await makeController(api: api, ledger: ledger, store: store,
                                                  rotator: rotator, spaceStore: spaceStore,
                                                  defaults: defaults)
        try await controller.removeThisDeviceFromSync()

        XCTAssertEqual(rotator.rotations, 1)
        XCTAssertEqual(ledger.steps.first, "retire")
        XCTAssertNil(controller.manager.currentARK)
        XCTAssertTrue(store.map.isEmpty)
        XCTAssertTrue(PhiSyncEngine.stateKeys.allSatisfy { defaults.object(forKey: $0) == nil })
        XCTAssertEqual(spaceStore.table, PhiSpaceSyncTable())
        XCTAssertFalse(controller.needsPairing)
    }

    /// CASE 3.2（M3-4a §4.4）— 自撤销第 4 步在两张游标表之外多删一次 `marker.json`：删，不是
    /// 存一张空表；第 1 步仍然严格先于一切清理；第 5 步的擦除面连两个 legacy 键一起擦。
    ///
    /// 防的是什么：三张游标表删了而 marker 留着，正好凑出 §4.4 论证里那个**灾难**方向的同族：
    /// 重新加入时 marker 说「我已经越过账户的全部历史」，于是那一次本该按身份把实体认回本机
    /// 行的整类型重放**一条实体都收不到**，而游标表是空的 ⇒ §5.7 的差分把整张表判成「本机
    /// 已删」⇒ 发出一批 tombstone，删掉账户上每一台设备的书签 / pin / 规则。
    func testSelfRevocationDeletesTheMarkerFileAlongsideBothCursorTables() async throws {
        let api = FakeAPI()
        let ledger = Ledger()
        let store = MemoryMappingStore()
        store.map = ["Default": "uuid-a"]
        let rotator = RecordingDeviceKeyStore(ledger: ledger)
        let spaceStore = PhiSyncEngineSpaceTests.MemorySpaceStore()
        let markerStore = MemoryMarkerStore(
            file: PhiSyncMarkerFile(marker: Data("m".utf8), storeBirthday: "B"))
        // 两张游标表都非空。
        var cursors = PhiOwnedItemTable()
        cursors.cursors["b1"] = PhiOwnedItemCursor()
        let bookmarkStore = MemoryOwnedItemStore(table: cursors)
        let pinStore = MemoryOwnedItemStore(table: cursors)
        let suite = "SelfRevokeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        for key in PhiSyncEngine.stateKeys { defaults.set("x", forKey: key) }
        // 一台迁移写失败的机器：两个 legacy 键还在（计划裁定 3 的擦除面要连它们一起擦）。
        for key in PhiSyncEngine.legacyMarkerStateKeys { defaults.set("x", forKey: key) }
        ProfilePairingGate.staticPendingOverride = true
        defer { ProfilePairingGate.staticPendingOverride = nil }

        let controller = try await makeController(api: api, ledger: ledger, store: store,
                                                  rotator: rotator, spaceStore: spaceStore,
                                                  defaults: defaults,
                                                  ownedItemStores: [bookmarkStore, pinStore],
                                                  markerStore: markerStore)
        try await controller.removeThisDeviceFromSync()

        XCTAssertTrue(markerStore.deleted, "`marker.json` 被删")
        XCTAssertTrue(bookmarkStore.deleted)
        XCTAssertTrue(pinStore.deleted)
        XCTAssertEqual(ledger.steps.first, "retire", "第 1 步仍然严格先于一切清理")
        XCTAssertTrue(markerStore.saves.isEmpty, "删，不是存一张空表")
        XCTAssertTrue(PhiSyncEngine.stateKeys.allSatisfy { defaults.object(forKey: $0) == nil })
        XCTAssertTrue(PhiSyncEngine.legacyMarkerStateKeys.allSatisfy { defaults.object(forKey: $0) == nil },
                      "第 5 步的擦除面连迁移残留一起擦")
    }
}

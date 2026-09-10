import XCTest
@testable import Phi

final class PhiSpaceSyncStateTests: XCTestCase {

    final class FakeStore: PhiSpaceSyncStateStore {
        var table = PhiSpaceSyncTable()
        private(set) var saves = 0
        func load() -> PhiSpaceSyncTable { table }
        func save(_ table: PhiSpaceSyncTable) { self.table = table; saves += 1 }
    }

    private func published(_ uuid: String, entityId: String = "srv-1") -> PhiSpaceCursor {
        var cursor = PhiSpaceCursor()
        cursor.entityId = entityId
        cursor.version = 4
        cursor.reconciled = Data([0x01])
        cursor.server = Data([0x01])
        return cursor
    }

    func testTableRoundTripsThroughCodableFieldByField() throws {
        var cursor = PhiSpaceCursor()
        cursor.entityId = "srv-1"
        cursor.version = 4
        cursor.reconciled = Data([0x01])
        cursor.server = Data([0x02])
        cursor.pendingApply = Data([0x03])
        cursor.heldProfileUuid = "held-uuid"
        cursor.heldForLocalProfileId = "Profile 1"
        cursor.pendingDelete = true
        cursor.deleteRejectRounds = 2
        cursor.pendingTombstone = true
        cursor.deletedAtMs = 11
        cursor.hidden = true
        cursor.refusedAtMs = 12
        cursor.purgedAtMs = 13

        var table = PhiSpaceSyncTable()
        table.cursors["sync-u1"] = cursor
        table.firstSyncDecision = "keepBoth"
        table.drainInProgress = true
        table.hasDrainedFullReplay = true
        table.hadRecords = true
        table.spaceSectionEnabled = true
        table.markerMovedWhileGateShut = true
        table.didReplayForEmptyTable = true
        table.lastDrainedBirthday = "b-1"
        table.unreadableTagHashes["abcd1234"] = 99

        let bytes = try JSONEncoder().encode(table)
        let back = try JSONDecoder().decode(PhiSpaceSyncTable.self, from: bytes)
        XCTAssertEqual(back, table)
        XCTAssertEqual(back.formatVersion, PhiSpaceSyncTable.currentFormatVersion)
        // 14 个游标字段一个不落：Equatable 是合成的，所以「逐个赋非默认值再比」就是
        // 逐字段断言；一个被漏掉的字段会让上面的 `back == table` 在它变化时仍然为真。
        XCTAssertEqual(back.cursors["sync-u1"], cursor)
    }

    // MARK: - formatVersion 硬切（§3.6）

    func testAnOlderFormatIsDiscardedIntoAnEmptyTable() throws {
        var old = PhiSpaceSyncTable()
        old.formatVersion = 1
        old.cursors["stale"] = PhiSpaceCursor()
        XCTAssertEqual(PhiSpaceSyncTable.loaded(from: old), PhiSpaceSyncTable())
        XCTAssertTrue(PhiSpaceSyncTable.isStaleFormat(rawData: try JSONEncoder().encode(old)))
    }

    func testACurrentFormatTableIsReturnedUnchanged() throws {
        var current = PhiSpaceSyncTable()
        current.cursors["sync-u1"] = PhiSpaceCursor()
        XCTAssertEqual(PhiSpaceSyncTable.loaded(from: current), current)
        XCTAssertFalse(PhiSpaceSyncTable.isStaleFormat(rawData: try JSONEncoder().encode(current)))
    }

    /// f7f37725 写下的 plist 里没有 `formatVersion` 键，合成的 `Decodable` 因此抛
    /// `keyNotFound` —— 这是硬切**实际生效**的那条路径，`>= 2` 那一句只是把规则
    /// 显式写出来。
    func testATableWithNoFormatVersionKeyCannotEvenDecode() {
        let raw = Data(#"{"cursors":{},"drainInProgress":false}"#.utf8)
        XCTAssertNil(try? JSONDecoder().decode(PhiSpaceSyncTable.self, from: raw))
        XCTAssertTrue(PhiSpaceSyncTable.isStaleFormat(rawData: raw))
        XCTAssertEqual(PhiSpaceSyncTable.loaded(from: nil), PhiSpaceSyncTable())
    }

    /// **没有键**（从没同步过的机器、刚登录的机器、ARK 一直锁着的机器）不是「旧表」。
    /// 缺了这一条，每一台首次启动的机器都会被判成「已丢弃」并把
    /// `ProfilePairingGate.joinPairingPending` 置真，而那个标志只能由一趟 `.measured`
    /// 退休 —— 离线的那次启动会让 Space 同步就此关上，既不弹模态也没有任何信号。
    func testAbsentDataIsNotAStaleTable() {
        XCTAssertFalse(PhiSpaceSyncTable.isStaleFormat(rawData: nil))
    }

    func testUndecodableBytesCountAsStale() {
        XCTAssertTrue(PhiSpaceSyncTable.isStaleFormat(rawData: Data([0x00, 0x01, 0x02])))
    }

    // MARK: - discardIfStaleFormat 的三条（§10.3）

    /// 每条用例一个全新的随机 userID，副作用是
    /// `FileSystemUtils.phiBrowserDataDirectory()/users/<uuid>/`，在 `tearDown` 里删掉。
    private var scratchAccounts: [Account] = []

    override func tearDown() {
        for account in scratchAccounts {
            try? FileManager.default.removeItem(at: account.userDataStorage)
        }
        scratchAccounts = []
        super.tearDown()
    }

    private func makeAccountStateStore() -> (AccountPhiSpaceSyncStateStore, AccountUserDefaults) {
        let account = Account(userID: UUID().uuidString)
        scratchAccounts.append(account)
        return (AccountPhiSpaceSyncStateStore(defaults: account.userDefaults), account.userDefaults)
    }

    func testAStaleTableOnDiskIsDiscardedIntoAnEmptyOne() throws {
        let (store, defaults) = makeAccountStateStore()
        var old = PhiSpaceSyncTable()
        old.formatVersion = 1
        old.cursors["stale"] = PhiSpaceCursor()
        defaults.set(old, forCodableKey: AccountPhiSpaceSyncStateStore.defaultsKey)

        XCTAssertTrue(store.discardIfStaleFormat())
        XCTAssertEqual(store.load(), PhiSpaceSyncTable(), "丢弃 = 写成一张当前版本的空表")
    }

    func testUndecodableBytesOnDiskAreDiscardedToo() {
        let (store, defaults) = makeAccountStateStore()
        defaults.set(Data([0x00, 0x01, 0x02]), forKey: AccountPhiSpaceSyncStateStore.defaultsKey)
        XCTAssertTrue(store.discardIfStaleFormat())
        XCTAssertEqual(store.load(), PhiSpaceSyncTable())
    }

    /// (c)：**键根本不存在** ⇒ 返回 false、`save` **零调用**（键在调用之后仍然不存在，
    /// 这就是「零调用」在这个 store 上唯一可观测的形式）、`joinPairingPending` 未被碰。
    /// 缺了这一条，每一台首次启动的机器都会被判成「已丢弃」而把 Space 段的门永久关上。
    @MainActor
    func testAnAbsentKeyIsNotDiscardedAndWritesNothing() {
        ProfilePairingGate.staticPendingOverride = false
        defer { ProfilePairingGate.staticPendingOverride = nil }
        let (store, defaults) = makeAccountStateStore()
        XCTAssertNil(defaults.data(forKey: AccountPhiSpaceSyncStateStore.defaultsKey))

        XCTAssertFalse(store.discardIfStaleFormat())

        XCTAssertNil(defaults.data(forKey: AccountPhiSpaceSyncStateStore.defaultsKey),
                     "guard 必须在 save 之前：没有键就一个字节都不许写")
        XCTAssertFalse(ProfilePairingGate.joinPairingPending,
                       "store 永远不碰那个标志——置真是协调器 `if` 的事（Step 5）")
    }

    // MARK: - recordLocalDeletion (§9.1: the criterion is entityId, not "has a cursor")

    func testRecordLocalDeletionMarksAPublishedSpace() {
        var table = PhiSpaceSyncTable()
        table.cursors["u1"] = published("u1")
        XCTAssertTrue(table.recordLocalDeletion(spaceId: "u1"))
        XCTAssertTrue(table.cursors["u1"]!.pendingDelete)
    }

    func testRecordLocalDeletionIgnoresANeverPublishedSpace() {
        var table = PhiSpaceSyncTable()
        XCTAssertFalse(table.recordLocalDeletion(spaceId: "never"))
        XCTAssertNil(table.cursors["never"])
    }

    /// The exact case the "has a cursor" criterion would get wrong: a refused
    /// agent entity owns a cursor carrying only `refusedAtMs`.
    func testRecordLocalDeletionIgnoresARefusedAgentEntity() {
        var table = PhiSpaceSyncTable()
        var refused = PhiSpaceCursor()
        refused.refusedAtMs = 1_700_000_000_000
        table.cursors["agent"] = refused
        XCTAssertFalse(table.recordLocalDeletion(spaceId: "agent"))
        XCTAssertFalse(table.cursors["agent"]!.pendingDelete)
    }

    func testRecordLocalDeletionIgnoresHiddenAndSoftDeletedSpaces() {
        var table = PhiSpaceSyncTable()
        var hidden = published("h")
        hidden.hidden = true
        hidden.entityId = nil
        table.cursors["h"] = hidden
        var softDeleted = published("d")
        softDeleted.deletedAtMs = 1_700_000_000_000
        table.cursors["d"] = softDeleted
        XCTAssertFalse(table.recordLocalDeletion(spaceId: "h"))
        XCTAssertFalse(table.recordLocalDeletion(spaceId: "d"))
    }

    // MARK: - hidden vs unsynced (§8.3)

    func testHiddenSyncUuidsCoverEveryHiddenCursor() {
        var table = PhiSpaceSyncTable()
        var softDeleted = PhiSpaceCursor()
        softDeleted.entityId = "srv-1"
        softDeleted.hidden = true
        softDeleted.deletedAtMs = 1_700_000_000_000
        table.cursors["sync-gone"] = softDeleted
        XCTAssertEqual(table.hiddenSyncUuids, ["sync-gone"])
        // `unsyncedSpaceIds` 的那半边断言随 D2 在 Task 9 一起删；这里不再喂一个
        // 「只有 hidden、没有 deletedAtMs」的 D2 游标，它违反新的不变量。
    }

    func testJoinAccountSyncIsANoOpForSoftDeletedOrAlreadyPublished() {
        var table = PhiSpaceSyncTable()
        var softDeleted = published("gone")
        softDeleted.hidden = true
        softDeleted.deletedAtMs = 1
        table.cursors["gone"] = softDeleted
        var published2 = published("pub")
        published2.hidden = true
        table.cursors["pub"] = published2
        var d2 = PhiSpaceCursor()
        d2.hidden = true
        table.cursors["local"] = d2

        XCTAssertFalse(table.joinAccountSync(spaceId: "gone"))
        XCTAssertTrue(table.cursors["gone"]!.hidden)
        XCTAssertFalse(table.joinAccountSync(spaceId: "pub"))
        XCTAssertTrue(table.cursors["pub"]!.hidden)
        XCTAssertTrue(table.joinAccountSync(spaceId: "local"))
        XCTAssertFalse(table.cursors["local"]!.hidden)
    }

    // MARK: - hidden ⇒ deletedAtMs != nil（R-D6-9 的新不变量）

    /// D6 之后 `hidden` 只剩一种含义：远端软删。D2 是唯一一个只写 `hidden` 不写
    /// `deletedAtMs` 的生产者，它随 Task 9 消失。一旦这条被破坏，那些行会从 strip
    /// 里静默消失，而 D2 时代的救援出口（设置段落）已经不在了。
    func assertHiddenImpliesDeleted(_ table: PhiSpaceSyncTable,
                                    file: StaticString = #filePath, line: UInt = #line) {
        for (uuid, cursor) in table.cursors where cursor.hidden {
            XCTAssertNotNil(cursor.deletedAtMs,
                            "cursor \(uuid) is hidden with no deletedAtMs", file: file, line: line)
        }
    }

    func testEveryTableMutatorKeepsHiddenImplyingDeleted() {
        var table = PhiSpaceSyncTable()
        var published = PhiSpaceCursor()
        published.entityId = "srv-1"
        published.version = 3
        table.cursors["sync-u1"] = published
        var softDeleted = PhiSpaceCursor()
        softDeleted.entityId = "srv-2"
        softDeleted.version = 3
        softDeleted.hidden = true
        softDeleted.deletedAtMs = 1_000
        table.cursors["sync-u2"] = softDeleted

        table.recordLocalDeletion(spaceId: "sync-u1")
        assertHiddenImpliesDeleted(table)
        _ = table.purgeExpired(nowMs: 1_000 + PhiSpaceSyncState.retentionMs + 1)
        assertHiddenImpliesDeleted(table)
    }

    // MARK: - 派生集合（§3.5）

    func testPublishedSyncUuidsHoldsOnlyCursorsWithAnEntityId() {
        var table = PhiSpaceSyncTable()
        var published = PhiSpaceCursor()
        published.entityId = "srv-1"
        table.cursors["sync-pub"] = published
        var refusedOnly = PhiSpaceCursor()
        refusedOnly.refusedAtMs = 5
        table.cursors["sync-refused"] = refusedOnly
        table.cursors["sync-never"] = PhiSpaceCursor()

        XCTAssertEqual(table.publishedSyncUuids, ["sync-pub"])
    }

    @MainActor
    func testHiddenSyncUuidsAreTranslatedBackToLocalIdsAndUnresolvableOnesAreDropped() {
        let state = PhiSpaceSyncState()
        state.localSpaceIdLookup = { $0 == "sync-a" ? "LOCAL-A" : nil }
        var table = PhiSpaceSyncTable()
        for uuid in ["sync-a", "sync-orphan"] {
            var cursor = PhiSpaceCursor()
            cursor.hidden = true
            cursor.deletedAtMs = 1
            table.cursors[uuid] = cursor
        }
        state.refreshCaches(from: table)
        XCTAssertEqual(state.hiddenSpaceIds, ["LOCAL-A"],
                       "交给 SpaceManager 漏斗的必须是一组本地 id；解析不到的丢弃")
        XCTAssertTrue(state.isHidden("LOCAL-A"))
    }

    @MainActor
    func testPublishedSyncUuidsDoNotFireTheHiddenSetNotification() {
        let state = PhiSpaceSyncState()
        state.localSpaceIdLookup = { _ in nil }
        var posts = 0
        let token = NotificationCenter.default.addObserver(
            forName: .phiSpaceHiddenSetDidChange, object: nil, queue: nil) { _ in posts += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        var table = PhiSpaceSyncTable()
        var published = PhiSpaceCursor()
        published.entityId = "srv-1"
        table.cursors["sync-pub"] = published
        state.refreshCaches(from: table)
        XCTAssertEqual(state.publishedSyncUuids, ["sync-pub"])
        XCTAssertEqual(posts, 0, "`.phiSpaceHiddenSetDidChange` 的语义不变：只看 hidden/unsynced")
    }

    // MARK: - 30-day sweep (§9.2)

    func testPurgeExpiredTrimsTheCursorToATombstoneAndKeepsIt() {
        var table = PhiSpaceSyncTable()
        var softDeleted = published("gone")
        softDeleted.hidden = true
        softDeleted.deletedAtMs = 1_000
        softDeleted.pendingApply = Data([0x09])
        softDeleted.heldProfileUuid = "held"
        table.cursors["gone"] = softDeleted

        let purged = table.purgeExpired(nowMs: 1_000 + PhiSpaceSyncState.retentionMs + 1)
        XCTAssertEqual(purged, ["gone"])
        let tombstone = try! XCTUnwrap(table.cursors["gone"])
        XCTAssertNotNil(tombstone.deletedAtMs)
        XCTAssertNotNil(tombstone.purgedAtMs)
        XCTAssertNotNil(tombstone.entityId)
        XCTAssertNil(tombstone.reconciled)
        XCTAssertNil(tombstone.server)
        XCTAssertNil(tombstone.pendingApply)
        XCTAssertNil(tombstone.heldProfileUuid)
    }

    func testPurgeExpiredLeavesFreshSoftDeletesAlone() {
        var table = PhiSpaceSyncTable()
        var softDeleted = published("gone")
        softDeleted.deletedAtMs = 1_000
        table.cursors["gone"] = softDeleted
        XCTAssertTrue(table.purgeExpired(nowMs: 1_000 + 60_000).isEmpty)
        XCTAssertNil(table.cursors["gone"]!.purgedAtMs)
    }

    // MARK: - profile references (§9.4 criteria 1 and 2)

    func testReferencesProfileUuidSeesBaselinesAndHeldBindings() throws {
        var entity = Phi_PhiSpaceEntity()
        entity.spaceUuid = "u1"
        var binding = Phi_PhiSettingValue()
        binding.updatedAtMs = 5
        binding.stringValue = "profile-uuid-a"
        entity.profileUuid = binding

        var table = PhiSpaceSyncTable()
        var cursor = published("u1")
        cursor.server = try entity.serializedData()
        table.cursors["u1"] = cursor
        var held = PhiSpaceCursor()
        held.entityId = "srv-2"
        held.heldProfileUuid = "profile-uuid-b"
        table.cursors["u2"] = held

        XCTAssertTrue(table.referencesProfileUuid("profile-uuid-a"))
        XCTAssertTrue(table.referencesProfileUuid("profile-uuid-b"))
        XCTAssertFalse(table.referencesProfileUuid("profile-uuid-c"))
    }

    func testReferencesProfileUuidIgnoresSoftDeletedCursors() throws {
        var entity = Phi_PhiSpaceEntity()
        entity.spaceUuid = "u1"
        var binding = Phi_PhiSettingValue()
        binding.stringValue = "profile-uuid-a"
        entity.profileUuid = binding
        var table = PhiSpaceSyncTable()
        var cursor = published("u1")
        cursor.server = try entity.serializedData()
        cursor.deletedAtMs = 42
        table.cursors["u1"] = cursor
        XCTAssertFalse(table.referencesProfileUuid("profile-uuid-a"))
    }

    // MARK: - single-writer facade fallback (§5.3 exception)

    @MainActor
    func testIntentsGoToTheSinkWhenAnEngineExists() {
        let state = PhiSpaceSyncState()
        var delivered: [String] = []
        state.intentSink = { intent in
            if case .recordLocalDeletion(let id) = intent { delivered.append(id) }
        }
        state.recordLocalDeletion(spaceId: "u1")
        XCTAssertEqual(delivered, ["u1"])
    }

    @MainActor
    func testIntentsHitDiskDirectlyWhenNoEngineExists() {
        let store = FakeStore()
        store.table.cursors["u1"] = published("u1")
        let state = PhiSpaceSyncState()
        state.directStore = store
        state.recordLocalDeletion(spaceId: "u1")
        XCTAssertTrue(store.table.cursors["u1"]!.pendingDelete)
        XCTAssertEqual(store.saves, 1)
    }

    /// R-D6-9：第三条判据从「hidden 的本地 Space」改成「**有映射且其实体已发布**的
    /// 本地 Space」。D6 之后 hidden 只剩远端软删一种含义，而软删的行不该再挡着一个
    /// Profile 被删。
    @MainActor
    func testBlocksProfileDeletionCoversMappedAndPublishedLocalSpaces() {
        let state = PhiSpaceSyncState()
        var table = PhiSpaceSyncTable()
        table.hasDrainedFullReplay = true
        var published = PhiSpaceCursor()
        published.entityId = "srv-1"
        table.cursors["sync-pub"] = published
        table.cursors["sync-never"] = PhiSpaceCursor()   // 有映射但从未发布
        state.refreshCaches(from: table)
        state.globalUuidLookup = { _ in nil }
        state.syncUuidLookup = { spaceId in
            ["LOCAL-PUB": "sync-pub", "LOCAL-NEVER": "sync-never"][spaceId]
        }
        state.localSpaceProfileIds = {
            [(spaceId: "LOCAL-PUB", profileId: "Profile 2"),
             (spaceId: "LOCAL-NEVER", profileId: "Profile 3"),
             (spaceId: "LOCAL-UNMAPPED", profileId: "Profile 4")]
        }
        XCTAssertTrue(state.blocksProfileDeletion(localProfileId: "Profile 2"))
        XCTAssertFalse(state.blocksProfileDeletion(localProfileId: "Profile 3"),
                       "有映射但从未发布 ⇒ 账户里没有它，删 Profile 不会孤立任何东西")
        XCTAssertFalse(state.blocksProfileDeletion(localProfileId: "Profile 4"), "无映射 ⇒ 不阻止")

        // §10.3 的末半句：`hasDrainedFullReplay == false` ⇒ **一律 false**（fail-open，
        // 不变）。第三条判据是新加的，它必须和前两条一样落在同一个 `guard` 后面——
        // 一次「还没排空重放就开始挡删除」会把一台刚加入的机器上的 Profile 删除口
        // 永久卡住，而这个 guard 是唯一的防线。
        var undrained = table
        undrained.hasDrainedFullReplay = false
        state.refreshCaches(from: undrained)
        XCTAssertFalse(state.blocksProfileDeletion(localProfileId: "Profile 2"),
                       "重放没排空 ⇒ fail-open，第三条判据也不例外")
    }

    /// R4: `blocksProfileDeletion` and `referencesProfileUuid` must be reading
    /// the SAME rule. Two copies of "deserialize both baselines, skip the
    /// soft-deleted, compare `profileUuid`" would drift and disagree about
    /// whether a Profile is deletable.
    @MainActor
    func testTheFacadeCacheAgreesWithTheTablePredicate() throws {
        var entity = Phi_PhiSpaceEntity()
        entity.spaceUuid = "u1"
        var binding = Phi_PhiSettingValue()
        binding.updatedAtMs = 5
        binding.stringValue = "uuid-a"
        entity.profileUuid = binding

        var table = PhiSpaceSyncTable()
        table.hasDrainedFullReplay = true
        var cursor = published("u1")
        cursor.server = try entity.serializedData()
        table.cursors["u1"] = cursor
        var held = PhiSpaceCursor()
        held.entityId = "srv-2"
        held.heldProfileUuid = "uuid-b"
        table.cursors["u2"] = held

        XCTAssertEqual(table.referencedProfileUuids(), ["uuid-a", "uuid-b"])
        let state = PhiSpaceSyncState()
        state.refreshCaches(from: table)
        state.localSpaceProfileIds = { [] }
        state.syncUuidLookup = { _ in nil }
        for (profileId, uuid) in [("P-a", "uuid-a"), ("P-b", "uuid-b"), ("P-c", "uuid-c")] {
            state.globalUuidLookup = { $0 == profileId ? uuid : nil }
            XCTAssertEqual(state.blocksProfileDeletion(localProfileId: profileId),
                           table.referencesProfileUuid(uuid),
                           "the facade cache and the table predicate disagree about \(uuid)")
        }
    }

    @MainActor
    func testBlocksProfileDeletionFailsOpenBeforeTheFirstDrain() {
        let state = PhiSpaceSyncState()
        var table = PhiSpaceSyncTable()
        table.hasDrainedFullReplay = false
        var cursor = PhiSpaceCursor()
        cursor.entityId = "srv"
        cursor.heldProfileUuid = "uuid-a"
        table.cursors["u1"] = cursor
        state.refreshCaches(from: table)
        state.globalUuidLookup = { $0 == "Profile 2" ? "uuid-a" : nil }
        state.localSpaceProfileIds = { [] }
        state.syncUuidLookup = { _ in nil }
        XCTAssertFalse(state.blocksProfileDeletion(localProfileId: "Profile 2"))
    }
}

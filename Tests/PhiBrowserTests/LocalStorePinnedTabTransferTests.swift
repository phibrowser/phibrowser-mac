// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import SwiftData
import XCTest
@testable import Phi

@MainActor
final class LocalStorePinnedTabTransferTests: XCTestCase {
    private var tempDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in tempDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        tempDirectories.removeAll()
    }

    func testSpaceTransferPreservesPersistedFieldsAndDeletesSourceAtomically() async throws {
        let store = try makeStoreWithSpaces()
        try await store.changePinnedTabScope(to: .space)
        let createdDate = Date(timeIntervalSince1970: 100)
        let updatedDate = Date(timeIntervalSince1970: 200)
        let lastSeen = Date(timeIntervalSince1970: 300)
        try insertPinned(
            in: store,
            guid: "source-pin",
            profileId: "Default",
            spaceId: "space-a",
            title: "Source",
            url: "https://origin.example",
            createdDate: createdDate,
            updatedDate: updatedDate,
            configure: { model in
                model.favicon = Data([1, 2, 3])
                model.overrideTitle = "Override"
                model.isOpenned = true
                model.isCreatedByChromium = true
                model.needUpdateMetaData = true
                model.source = TabSource.arc.rawValue
                model.secondaryUrl = URL(string: "https://secondary.example")
                model.secondaryTitle = "Secondary"
                model.lastSeen = lastSeen
                model.pinLineageId = "source-lineage"
            }
        )

        let result = try await store.transferPinnedTab(
            guid: "source-pin",
            sourceProfileId: "Default",
            sourceSpaceId: "space-a",
            targetProfileId: "Default",
            targetSpaceId: "space-b",
            destinationIndex: 0
        )
        drainMainQueue()

        XCTAssertTrue(store.getAllPinnedTabs(for: "Default", spaceId: "space-a").isEmpty)
        let copied = try XCTUnwrap(store.getAllPinnedTabs(for: "Default", spaceId: "space-b").first)
        XCTAssertEqual(result.guidMapping["source-pin"], copied.guid)
        XCTAssertNotEqual(copied.guid, "source-pin")
        XCTAssertEqual(copied.title, "Source")
        XCTAssertEqual(copied.url.absoluteString, "https://origin.example")
        XCTAssertEqual(copied.favicon, Data([1, 2, 3]))
        XCTAssertEqual(copied.overrideTitle, "Override")
        XCTAssertTrue(copied.isOpenned)
        XCTAssertTrue(copied.isCreatedByChromium)
        XCTAssertTrue(copied.needUpdateMetaData)
        XCTAssertEqual(copied.source, TabSource.arc.rawValue)
        XCTAssertEqual(copied.secondaryUrl?.absoluteString, "https://secondary.example")
        XCTAssertEqual(copied.secondaryTitle, "Secondary")
        XCTAssertEqual(copied.createdDate, createdDate)
        XCTAssertEqual(copied.lastSeen, lastSeen)
        XCTAssertEqual(copied.pinLineageId, "source-lineage")
        XCTAssertEqual(copied.profileId, "Default")
        XCTAssertEqual(copied.spaceId, "space-b")
    }

    func testSpaceTransferMovesWholeSplitAndNormalizesPartnerGuids() async throws {
        let store = try makeStoreWithSpaces()
        try await store.changePinnedTabScope(to: .space)
        try insertPinned(
            in: store,
            guid: "left",
            profileId: "Default",
            spaceId: "space-a",
            title: "Left",
            url: "https://left.example",
            index: 0,
            configure: { $0.splitPartnerGuid = "right" }
        )
        try insertPinned(
            in: store,
            guid: "right",
            profileId: "Default",
            spaceId: "space-a",
            title: "Right",
            url: "https://right.example",
            index: 1
        )

        let result = try await store.transferPinnedTab(
            guid: "left",
            sourceProfileId: "Default",
            sourceSpaceId: "space-a",
            targetProfileId: "Default",
            targetSpaceId: "space-b",
            destinationIndex: 0
        )
        drainMainQueue()

        XCTAssertTrue(result.isSplit)
        XCTAssertTrue(store.getAllPinnedTabs(for: "Default", spaceId: "space-a").isEmpty)
        let target = store.getAllPinnedTabs(for: "Default", spaceId: "space-b")
        XCTAssertEqual(target.count, 2)
        XCTAssertEqual(target[0].guid, result.guidMapping["left"])
        XCTAssertEqual(target[1].guid, result.guidMapping["right"])
        XCTAssertEqual(target[0].splitPartnerGuid, target[1].guid)
        XCTAssertEqual(target[1].splitPartnerGuid, target[0].guid)
    }

    func testLivePartnerHintTransfersPairBeforePersistedLinksAreWritten() async throws {
        let store = try makeStoreWithSpaces()
        try await store.changePinnedTabScope(to: .space)
        try insertPinned(
            in: store,
            guid: "left",
            profileId: "Default",
            spaceId: "space-a",
            title: "Left",
            url: "https://left.example",
            index: 0
        )
        try insertPinned(
            in: store,
            guid: "right",
            profileId: "Default",
            spaceId: "space-a",
            title: "Right",
            url: "https://right.example",
            index: 1
        )

        let result = try await store.transferPinnedTab(
            guid: "left",
            sourceProfileId: "Default",
            sourceSpaceId: "space-a",
            targetProfileId: "Default",
            targetSpaceId: "space-b",
            partnerGuidHint: "right",
            destinationIndex: 0
        )
        drainMainQueue()

        XCTAssertTrue(result.isSplit)
        XCTAssertTrue(store.getAllPinnedTabs(for: "Default", spaceId: "space-a").isEmpty)
        let target = store.getAllPinnedTabs(for: "Default", spaceId: "space-b")
        XCTAssertEqual(target.count, 2)
        XCTAssertEqual(target[0].splitPartnerGuid, target[1].guid)
        XCTAssertEqual(target[1].splitPartnerGuid, target[0].guid)
    }

    func testSharedProfileOwnerReordersWithoutReplacingPhysicalGuid() async throws {
        let store = try makeStoreWithSpaces()
        for (index, guid) in ["a", "b", "c"].enumerated() {
            try insertPinned(
                in: store,
                guid: guid,
                profileId: "Default",
                spaceId: nil,
                title: guid.uppercased(),
                url: "https://\(guid).example",
                index: index
            )
        }

        let result = try await store.transferPinnedTab(
            guid: "a",
            sourceProfileId: "Default",
            sourceSpaceId: "space-a",
            targetProfileId: "Default",
            targetSpaceId: "space-b",
            destinationIndex: 2
        )
        drainMainQueue()

        XCTAssertEqual(result.guidMapping, ["a": "a"])
        XCTAssertEqual(
            store.getAllPinnedTabs(for: "Default", spaceId: "space-b").map(\.guid),
            ["b", "c", "a"]
        )

        let rawGapResult = try await store.transferPinnedTab(
            guid: "b",
            sourceProfileId: "Default",
            sourceSpaceId: "space-a",
            targetProfileId: "Default",
            targetSpaceId: "space-b",
            destinationIndex: 2,
            destinationIndexIncludesSourceUnit: true
        )
        drainMainQueue()

        XCTAssertEqual(rawGapResult.guidMapping, ["b": "b"])
        XCTAssertEqual(
            store.getAllPinnedTabs(for: "Default", spaceId: "space-b").map(\.guid),
            ["c", "b", "a"]
        )
    }

    func testNormalSplitCreationUsesTargetSpaceOwnerAndPersistsPair() async throws {
        let store = try makeStoreWithSpaces()
        try await store.changePinnedTabScope(to: .space)

        let result = try await store.createPinnedTabsForCrossWindowDrop(
            [
                PinnedTabCreationInput(
                    tabId: 10,
                    title: "Left",
                    url: "https://left.example",
                    partnerTabId: 11
                ),
                PinnedTabCreationInput(
                    tabId: 11,
                    title: "Right",
                    url: "https://right.example",
                    partnerTabId: 10
                ),
            ],
            targetProfileId: "Default",
            targetSpaceId: "space-b",
            destinationIndex: 0
        )
        drainMainQueue()

        XCTAssertTrue(result.isSplit)
        XCTAssertTrue(store.getAllPinnedTabs(for: "Default", spaceId: "space-a").isEmpty)
        let target = store.getAllPinnedTabs(for: "Default", spaceId: "space-b")
        XCTAssertEqual(
            target.map(\.guid),
            [try XCTUnwrap(result.guidByTabId[10]), try XCTUnwrap(result.guidByTabId[11])]
        )
        XCTAssertEqual(target[0].splitPartnerGuid, target[1].guid)
        XCTAssertEqual(target[1].splitPartnerGuid, target[0].guid)
    }

    // MARK: - 作用域迁移的合并键（R-M3-3-16）

    // CASE 2b.1 —— `contentSignature(for:)` 今天是 `(title, url, favicon)`，而
    // `mergeCandidates` 只在签名相等时才合并同 lineage 的两份副本。D9 让 favicon 留在
    // 设备本地并各自回填，所以两台机器对同一条 pin 合法地持有不同的 favicon 字节——于是
    // 同一次账户级作用域变更在 A 上合出 1 行、在 B 上合出 2 行，两台机器的 pin 数量从此
    // 不同，且各自都认为自己是对的。
    func testScopeMigrationMergesLineageAcrossDifferingFaviconBytes() async throws {
        let store = try makeStoreWithSpaces()
        try await store.changePinnedTabScope(to: .space)
        try insertPinned(
            in: store,
            guid: "p1",
            profileId: "Default",
            spaceId: "space-a",
            title: "Shared",
            url: "https://shared.example",
            configure: { model in
                model.pinLineageId = "L"
                model.favicon = Data([0x1])
            }
        )
        try insertPinned(
            in: store,
            guid: "p2",
            profileId: "Default",
            spaceId: "space-b",
            title: "Shared",
            url: "https://shared.example",
            configure: { model in
                model.pinLineageId = "L"
                model.favicon = nil
            }
        )

        try await store.changePinnedTabScope(
            to: .profile,
            preferredProfileId: "Default",
            preferredSpaceId: "space-a"
        )
        drainMainQueue()

        let merged = store.getAllPinnedTabs(for: "Default").filter { $0.pinLineageId == "L" }
        XCTAssertEqual(merged.count, 1)
    }

    // CASE 5b.5 —— R-M3-3-16 的双 fixture 回归：**两台机器**的 favicon 不同，同一次作用域
    // 迁移的结果逐行相同。
    //
    // 防的是什么：CASE 2b.1 只测了「同一台机器上两份变体合成一条」，那是必要条件不是充分
    // 条件。真正的故障形状是**两台机器合出不同的结果**，而那要两份 fixture 才看得见。D9 让
    // favicon 留在本地并各自回填，所以「同一条 pin 在两台机器上有不同的 favicon」是**常态**；
    // 合并键一旦沾上它，两台机器的 pin 数量会从此不同，且各自都认为自己是对的。
    func testTwoDevicesWithDifferentFaviconBytesMigrateToIdenticalRows() async throws {
        // A：每一条都有图。B：每一条都是 nil。其余字段（lineage / title / url / index）逐字
        // 相同——两台机器本来就该在这里一致。
        let deviceA = try await makeMigrationFixtureStore(favicons: [Data([0x1]), Data([0x2])])
        let deviceB = try await makeMigrationFixtureStore(favicons: [nil, nil])

        for store in [deviceA, deviceB] {
            try await store.changePinnedTabScope(
                to: .profile,
                preferredProfileId: "Default",
                preferredSpaceId: "space-a"
            )
        }
        drainMainQueue()

        let rowsA = migratedRows(in: deviceA)
        let rowsB = migratedRows(in: deviceB)
        XCTAssertEqual(rowsA.count, rowsB.count, "两台机器合出的条数必须相同")
        XCTAssertEqual(rowsA.map(\.lineage), rowsB.map(\.lineage))
        XCTAssertEqual(rowsA.map(\.index), rowsB.map(\.index))
        XCTAssertEqual(rowsA.map(\.title), rowsB.map(\.title))
        XCTAssertEqual(rowsA.map(\.url), rowsB.map(\.url))
    }

    // MARK: - applyPinSyncBatchThrowing（Task 5b）

    // CASE 5b.4b ③ 的 store 级对应物 —— 整批一个事务：中途一条 op 失败，前面那些也回滚。
    //
    // 防的是什么：那五个 throwing 兄弟各自开一个写块，挨个调就是 N 个事务、部分成功于是
    // 成立，而引擎会为一批只落了一半的操作写下基线（R-exec-2）。
    func testAFailingOpRollsBackEveryEarlierOpInTheSameBatch() async throws {
        let store = try makeStoreWithSpaces()
        try insertPinned(in: store, guid: "p-a", profileId: "Default", spaceId: nil,
                         title: "A", url: "https://a.example", index: 0)

        await assertThrows(.rowNotFound) {
            try await store.applyPinSyncBatchThrowing([
                .update(guid: "p-a", fields: PinFieldPatch(title: "Renamed")),
                .delete(guid: "no-such-guid"),
            ])
        }

        let title = try pinRow("p-a", in: store)?.title
        XCTAssertEqual(title, "A", "部分成功不存在")
    }

    // 末尾按被触及的每个 **owner** 跑一次 index 重排（pin 按 owner 分组，不是按父）。
    //
    // 防的是什么：一批操作可能反复动同一个 owner，每条各自那次重排只保证它自己那一刻是
    // 稠密的。留下的空位会让下一轮的 rank → index 投影算出与对端不同的次序，两台机器的 pin
    // 顺序就此分歧。
    func testTheBatchLeavesEveryTouchedOwnerDenselyNumbered() async throws {
        let store = try makeStoreWithSpaces()
        for (index, guid) in ["p-0", "p-1", "p-2"].enumerated() {
            try insertPinned(in: store, guid: guid, profileId: "Default", spaceId: nil,
                             title: guid, url: "https://\(guid).example", index: index)
        }

        // 中间那条被删掉，于是 0 / 2 之间留下一个空位，收尾那次重排要把它补上。
        try await store.applyPinSyncBatchThrowing([.delete(guid: "p-1")])
        drainMainQueue()

        let remaining = store.getAllPinnedTabs(for: "Default")
            .sorted { ($0.index, $0.guid) < ($1.index, $1.guid) }
        XCTAssertEqual(remaining.map(\.guid), ["p-0", "p-2"])
        XCTAssertEqual(remaining.map(\.index), [0, 1], "空位被补上")
    }

    // 导入中的 Space 抛的是那个**专属**的 case，不是 `targetNotWritable`，而且一个字节都不落。
    //
    // 防的是什么：`targetNotWritable` 的含义是「Space 被删了或换了 Profile」，那是结构性
    // 失败；导入是瞬时状态，引擎该按停放处理、下一轮重试。两者混用之后 §11.2 的 `parked`
    // 计数分不清一次该重试的停放与一次不该重试的失败。
    func testABatchTargetingAnImportingSpaceThrowsTheDedicatedCase() async throws {
        let store = try makeStoreWithSpaces()
        try await store.changePinnedTabScope(to: .space)
        try insertPinned(in: store, guid: "p-a", profileId: "Default", spaceId: "space-a",
                         title: "A", url: "https://a.example")
        ImportTargetLock.shared.begin(into: "space-a")
        defer { ImportTargetLock.shared.end(into: "space-a") }

        await assertThrows(.spaceImporting(spaceId: "space-a")) {
            try await store.applyPinSyncBatchThrowing([
                .update(guid: "p-a", fields: PinFieldPatch(title: "Renamed")),
            ])
        }

        let title = try pinRow("p-a", in: store)?.title
        XCTAssertEqual(title, "A", "锁住时一个字节都不落")
    }

    // `.create` 的 `source` 一路落到物理行上（Step 2）。
    //
    // 防的是什么：`PhiPinTabEntity` 的字段 8 就是 `source`，`PinKind.merge` 按「取非零一侧」
    // 合并它。缺这个参数，一条远端 pin 落地时它只能落成默认值 0，下一轮的快照把 0 当成本机
    // 的值发回去，把对端记录的导入来源抹掉。
    func testCreateCarriesSourceAndLineageAndCreatedDateOntoTheRow() async throws {
        let store = try makeStoreWithSpaces()
        let born = Date(timeIntervalSince1970: 7_777)

        try await store.createPinnedTabThrowing(
            guid: "p-new",
            url: try XCTUnwrap(URL(string: "https://new.example")),
            title: "New",
            profileId: "Default",
            lineageId: "l-remote",
            createdDate: born,
            source: TabSource.safari.rawValue
        )
        drainMainQueue()

        let landed = try XCTUnwrap(try pinRow("p-new", in: store))
        XCTAssertEqual(landed.source, TabSource.safari.rawValue)
        XCTAssertEqual(landed.pinLineageId, "l-remote", "线上身份原样写回，不重铸")
        XCTAssertEqual(landed.createdDate, born)
    }

    // 一条拆分补丁把**两个**方向写在同一个事务里（§7.4 / I11），伙伴按归一后的 lineage 解析。
    //
    // 防的是什么：`reconcilePinnedSplitPartners()` 遍历的是活动窗口里的 `SplitGroup`，而一对
    // 由同步落地的拆分 pin 没有任何活动 group——只写一个方向的话，另一半永远不知道自己被
    // 配了对。本机那一列可能是大写，直接比恒为假，于是每一次链接都抛 `rowNotFound`。
    func testASplitPartnerPatchLinksBothDirectionsThroughTheNormalisedLineage() async throws {
        let store = try makeStoreWithSpaces()
        try insertPinned(in: store, guid: "p-left", profileId: "Default", spaceId: nil,
                         title: "Left", url: "https://left.example", index: 0,
                         configure: { $0.pinLineageId = "L-LEFT" })
        try insertPinned(in: store, guid: "p-right", profileId: "Default", spaceId: nil,
                         title: "Right", url: "https://right.example", index: 1,
                         configure: { $0.pinLineageId = "L-RIGHT" })

        // 补丁带的是线上归一过的小写 lineage，而本机那一列是大写。
        try await store.applyPinSyncBatchThrowing([
            .update(guid: "p-left", fields: PinFieldPatch(splitPartnerLineageId: "l-right")),
        ])
        drainMainQueue()

        XCTAssertEqual(try pinRow("p-left", in: store)?.splitPartnerGuid, "p-right")
        XCTAssertEqual(try pinRow("p-right", in: store)?.splitPartnerGuid, "p-left",
                       "反向也在同一个事务里写了")
    }

    // MARK: - updateActivePinnedTabThrowing / removeActivePinnedTabThrowing

    // CASE 2b.2 —— 「guid 不在当前作用域」是 fail-closed 的设计、不是 bug，但对同步层
    // 必须可见：引擎会把一次没发生的写当成落地并写下基线。
    func testUpdateActivePinnedTabThrowingRejectsARowOutsideTheActiveScope() async throws {
        let store = try await makeStoreWithAnInactiveSpaceBPin()

        await assertThrows(.rowNotInActiveScope) {
            try await store.updateActivePinnedTabThrowing(
                guid: "space-b-pin",
                url: URL(string: "https://edited.example"),
                title: "Edited"
            )
        }
    }

    // CASE 2b.3 —— 与 2b.2 是两个不同的入口，各测一次（§4.9 穷举的是「两个
    // `…ActivePinnedTab` 各一条」）。
    func testRemoveActivePinnedTabThrowingRejectsARowOutsideTheActiveScope() async throws {
        let store = try await makeStoreWithAnInactiveSpaceBPin()

        await assertThrows(.rowNotInActiveScope) {
            try await store.removeActivePinnedTabThrowing(guid: "space-b-pin")
        }
    }

    // CASE 2b.4
    func testRemoveActivePinnedTabThrowingThrowsWhenTheRowIsMissing() async throws {
        let store = try makeStoreWithSpaces()
        try await store.changePinnedTabScope(to: .space)

        await assertThrows(.rowNotFound) {
            try await store.removeActivePinnedTabThrowing(guid: "no-such-guid")
        }
    }

    // 一条属于 `space-b` 的 pin，在一次以 `space-a` 为 preferred 的作用域变更之后被留成
    // 作用域外的备份行：`migratePinnedTabs` 保留源行、另建新的 Profile 形状物理行，所以
    // 一个在这次交接期间排好队的 UI 动作仍然会带着旧 guid 打过来。
    private func makeStoreWithAnInactiveSpaceBPin() async throws -> LocalStore {
        let store = try makeStoreWithSpaces()
        try await store.changePinnedTabScope(to: .space)
        try insertPinned(
            in: store,
            guid: "space-b-pin",
            profileId: "Default",
            spaceId: "space-b",
            title: "B",
            url: "https://b.example"
        )
        try await store.changePinnedTabScope(
            to: .profile,
            preferredProfileId: "Default",
            preferredSpaceId: "space-a"
        )
        drainMainQueue()
        return store
    }

    private func assertThrows(_ expected: LocalStoreWriteError,
                              file: StaticString = #filePath,
                              line: UInt = #line,
                              _ block: () async throws -> Void) async {
        do {
            try await block()
            XCTFail("Expected \(expected) to be thrown.", file: file, line: line)
        } catch let error as LocalStoreWriteError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }

    /// 一台机器的迁移 fixture：Space 作用域，`space-a` / `space-b` 各一条同 lineage、同
    /// title、同 url、同 index 的 pin，**唯一差别是 favicon 字节**。
    private func makeMigrationFixtureStore(favicons: [Data?]) async throws -> LocalStore {
        let store = try makeStoreWithSpaces()
        try await store.changePinnedTabScope(to: .space)
        for (offset, spaceId) in ["space-a", "space-b"].enumerated() {
            try insertPinned(
                in: store,
                guid: "pin-\(spaceId)",
                profileId: "Default",
                spaceId: spaceId,
                title: "Shared",
                url: "https://shared.example",
                configure: { model in
                    model.pinLineageId = "shared-lineage"
                    model.favicon = favicons[offset]
                }
            )
        }
        return store
    }

    /// 迁移之后那个 Profile 集合的逐行取值，按 `(index, guid)` 有序。**只取参与身份与顺序
    /// 的字段**：favicon 按 D9 本来就该在两台机器上不同。
    private func migratedRows(in store: LocalStore)
        -> [(lineage: String, index: Int, title: String, url: String)] {
        store.getAllPinnedTabs(for: "Default")
            .sorted { ($0.index, $0.guid) < ($1.index, $1.guid) }
            .map { (lineage: $0.pinLineageId ?? $0.guid,
                    index: $0.index,
                    title: $0.title,
                    url: $0.url.absoluteString) }
    }

    private func pinRow(_ guid: String, in store: LocalStore) throws -> TabDataModel? {
        let context = try XCTUnwrap(store.getMainContext())
        let pinnedRaw = TabDataType.pinnedTab.rawValue
        return try context.fetch(FetchDescriptor<TabDataModel>(
            predicate: #Predicate { $0.guid == guid && $0.type == pinnedRaw }
        )).first
    }

    private func makeStoreWithSpaces() throws -> LocalStore {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectories.append(directory)
        let store = LocalStore(
            account: Account(userID: UUID().uuidString),
            storeDirectoryURL: directory,
            presentsCompatibilityAlerts: false
        )
        let context = try XCTUnwrap(store.getMainContext())
        context.insert(ProfileModel(profileId: "Default"))
        context.insert(SpaceModel(
            spaceId: "space-a",
            profileId: "Default",
            name: "A",
            colorHex: "#000000",
            iconName: "star",
            sortOrder: 0
        ))
        context.insert(SpaceModel(
            spaceId: "space-b",
            profileId: "Default",
            name: "B",
            colorHex: "#000000",
            iconName: "star",
            sortOrder: 1
        ))
        try context.save()
        return store
    }

    private func insertPinned(
        in store: LocalStore,
        guid: String,
        profileId: String,
        spaceId: String?,
        title: String,
        url: String,
        index: Int = 0,
        createdDate: Date = Date(),
        updatedDate: Date = Date(),
        configure: (TabDataModel) -> Void = { _ in }
    ) throws {
        let context = try XCTUnwrap(store.getMainContext())
        let profile = try XCTUnwrap(
            try context.fetch(FetchDescriptor<ProfileModel>()).first(where: {
                $0.profileId == profileId
            })
        )
        let model = TabDataModel(
            title: title,
            guid: guid,
            index: index,
            url: try XCTUnwrap(URL(string: url)),
            favicon: nil,
            createdDate: createdDate,
            updatedDate: updatedDate
        )
        model.dataType = .pinnedTab
        model.profile = profile
        model.profileId = profileId
        model.spaceId = spaceId
        model.pinLineageId = guid
        configure(model)
        context.insert(model)
        try context.save()
    }

    private func drainMainQueue() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
}

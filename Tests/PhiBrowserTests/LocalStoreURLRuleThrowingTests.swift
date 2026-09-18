// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Combine
import SwiftData
import XCTest
@testable import Phi

// URL 规则存储侧的 throwing 兄弟（M3-4a）。Task 4 放 CASE C-1 / C-2 / C-10 / C-11；
// Task 5 往同一个文件里追加 C-6 ~ C-9、C-12、U-6、U-15e、置位表、U-13 / U-13c、U-14-legacy。
//
// 与 `LocalStoreCompatibilityTests` 的分工：那个文件整个跑在文本占位文件与两个一次性
// schema 上，打不开一个真的 V10 库，也永远跑不到 `migrateV10toV11` 一行（RT-8）。全仓除
// `LocalStore.swift` 与 `AppController+UserDataBackup.swift` 两个生产引用外没有任何测试引用
// `TabDataModelMigrationPlan`——这里的 C-1 / C-11 是整条 V10 → V11 迁移唯一的真库探针。
@MainActor
final class LocalStoreURLRuleThrowingTests: XCTestCase {
    private var tempDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in tempDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        tempDirectories.removeAll()
    }

    // MARK: - CASE C-1 —— 真库 V10 → V11 迁移

    // 防的是什么：没有这一条，「五个模型漏声明一个」「新列打错类型让 lightweight 退化成需要
    // 自定义映射」「回填铸的是大写 uuid」三种缺陷全部绿着上线。
    func testV10StoreMigratesToV11PreservingEveryRuleAndBackfillingSyncId() throws {
        let directory = try makeTemporaryDirectory()
        let seeded = try seedV10Store(at: directory, rules: Self.fourRules)

        let container = try openWithProductionMigrationPlan(at: directory)
        let context = container.mainContext

        let profiles = try context.fetch(FetchDescriptor<ProfileModel>())
        let spaces = try context.fetch(FetchDescriptor<SpaceModel>())
        let tabs = try context.fetch(FetchDescriptor<TabDataModel>())
        let rules = try context.fetch(FetchDescriptor<SpaceURLRule>(
            sortBy: [SortDescriptor(\.spaceId), SortDescriptor(\.sortOrder)]
        ))

        // 行数逐类不变。
        XCTAssertEqual(profiles.count, 2)
        XCTAssertEqual(spaces.count, 3)
        XCTAssertEqual(tabs.count, seeded.tabCount)
        XCTAssertEqual(rules.count, 4)
        XCTAssertEqual(Set(profiles.map(\.profileId)), Set(seeded.profileIds))
        XCTAssertEqual(Set(spaces.map(\.spaceId)), Set(seeded.spaceIds))
        XCTAssertEqual(Set(tabs.map(\.guid)), Set(seeded.tabGuids))

        // 每条规则的七个 V10 字段逐字保留（含那条 `pathPrefix == nil`）。
        let byId = Dictionary(uniqueKeysWithValues: rules.map { ($0.id, $0) })
        XCTAssertEqual(Set(byId.keys), Set(Self.fourRules.map(\.id)))
        for seed in Self.fourRules {
            let row = try XCTUnwrap(byId[seed.id], "rule \(seed.id) vanished in the migration")
            XCTAssertEqual(row.spaceId, seed.spaceId)
            XCTAssertEqual(row.host, seed.host)
            XCTAssertEqual(row.pathPrefix, seed.pathPrefix)
            XCTAssertEqual(row.askBeforeRouting, seed.askBeforeRouting)
            XCTAssertEqual(row.sortOrder, seed.sortOrder)
            XCTAssertEqual(row.createdDate, seed.createdDate)
        }
        XCTAssertTrue(Self.fourRules.contains { $0.pathPrefix == nil })

        // `syncId` 四条全部非 nil、互不相同、小写（R-M3-4a-23 的回填）。
        let syncIds = try rules.map { try XCTUnwrap($0.syncId, "rule \($0.id) has no syncId after migration") }
        XCTAssertEqual(Set(syncIds).count, 4)
        for syncId in syncIds {
            XCTAssertEqual(syncId, syncId.lowercased())
            XCTAssertNotNil(UUID(uuidString: syncId))
        }

        // 其余五列保持默认。
        for row in rules {
            XCTAssertNil(row.contentUpdatedDate)
            XCTAssertNil(row.targetUpdatedDate)
            XCTAssertNil(row.deletedDate)
            XCTAssertFalse(row.pendingLocalEdit)
            XCTAssertNil(row.mergePartnerSyncId)
        }

        // `ProfileModel` 的两列在 M3-4a 里是死列：迁移不回填。
        for profile in profiles {
            XCTAssertNil(profile.syncId)
            XCTAssertNil(profile.createdDate)
        }
    }

    // MARK: - CASE C-2 —— 迁移计划的结构断言

    // 防的是什么：漏把 `migrateV10toV11` 加进 `stages` 时今天没有任何东西会发现——`schemas`
    // 里有 V11、typealias 指向 V11，SwiftData 会按 lightweight 推断跑通，于是 `didMigrate`
    // 的 `syncId` 回填整个不执行。这一条是它唯一的探测器。
    func testMigrationPlanEndsAtV11WithOneStagePerUpgrade() throws {
        let schemas = TabDataModelMigrationPlan.schemas
        let stages = TabDataModelMigrationPlan.stages

        XCTAssertEqual(schemas.count, 11)
        XCTAssertEqual(stages.count, schemas.count - 1)
        let last = try XCTUnwrap(schemas.last)
        XCTAssertEqual(ObjectIdentifier(last), ObjectIdentifier(TabDataModelSchemaV11.self))
        XCTAssertEqual(TabDataModelSchemaV11.versionIdentifier, Schema.Version(11, 0, 0))
        XCTAssertEqual(TabDataModelSchemaV11.models.count, 5)
    }

    // MARK: - CASE C-10 —— `deletedDate` 的默认读过滤（R-M3-4a-51）

    // 防的是什么：软删行留在默认读口里就留在了稠密 `sortOrder` 重排的定义域里——删除方桶里
    // 它占着下标，而跟随端（入站 tombstone 是硬删）没有它，于是同一条规则在两台上的
    // `sortOrder` 相差「它前面软删行的条数」，跨 Space 平手时两台裁出不同赢家。漏改
    // publisher 那一条还会让编辑器与 Chromium 的路由表继续显示并继续路由一条已删的规则。
    func testDefaultReadPathsHideSoftDeletedRules() throws {
        let directory = try makeTemporaryDirectory()
        let store = LocalStore(
            account: Account(userID: UUID().uuidString),
            storeDirectoryURL: directory,
            presentsCompatibilityAlerts: false
        )
        let context = try XCTUnwrap(store.getMainContext())

        // 先订阅并取到首发值（空库），再插行、再 save。
        var emissions: [[SpaceURLRule]] = []
        let postSave = expectation(description: "urlRulesPublisher re-emits after the save")
        let cancellable = store.urlRulesPublisher()
            .sink { rules in
                emissions.append(rules)
                if emissions.count == 2 { postSave.fulfill() }
            }
        defer { cancellable.cancel() }
        XCTAssertEqual(emissions.count, 1)
        XCTAssertEqual(emissions.first?.count, 0)

        let softDeletedId = "a-1"
        context.insert(SpaceURLRule(id: "a-0", spaceId: "space-a", host: "a.example", sortOrder: 0))
        context.insert(SpaceURLRule(id: softDeletedId, spaceId: "space-a", host: "b.example", sortOrder: 1,
                                    deletedDate: Date()))
        context.insert(SpaceURLRule(id: "a-2", spaceId: "space-a", host: "c.example", sortOrder: 2))
        context.insert(SpaceURLRule(id: "b-0", spaceId: "space-b", host: "d.example", sortOrder: 0))
        try context.save()

        // ① 全量读口。
        let all = store.getAllURLRules()
        XCTAssertEqual(all.map(\.id), ["a-0", "a-2", "b-0"])
        XCTAssertFalse(all.contains { $0.id == softDeletedId })

        // ② 按 Space 读口：不做重编号，`sortOrder` 序列是 [0, 2]。
        let spaceA = store.getURLRules(forSpaceId: "space-a")
        XCTAssertEqual(spaceA.map(\.id), ["a-0", "a-2"])
        XCTAssertEqual(spaceA.map(\.sortOrder), [0, 2])

        // ③ publisher 在 `NSManagedObjectContextDidSave` 之后发出的那一次值。
        wait(for: [postSave], timeout: 5)
        XCTAssertEqual(emissions.count, 2)
        let published = try XCTUnwrap(emissions.last)
        XCTAssertEqual(published.map(\.id), all.map(\.id))
        XCTAssertEqual(published.map(\.spaceId), all.map(\.spaceId))
        XCTAssertEqual(published.map(\.sortOrder), all.map(\.sortOrder))
        XCTAssertFalse(published.contains { $0.id == softDeletedId })
    }

    // MARK: - CASE C-11 —— `syncId` 回填：n 行 → n 个互不相同的小写 uuid，且幂等（R-M3-4a-23）

    // 防的是什么：(a) 回填不 `.lowercased()` 时，本机身份与账户上其它设备铸的小写 uuid 大小写
    // 不一致，按 `syncId` 寻址的 per-row 原语会在同一条规则上分裂成两条；(b) 回填不带
    // `where rule.syncId == nil` 守卫时，任何一次重跑都会给已经发布过的行重铸身份——账户上那条
    // 实体瞬间变成孤儿，终态两条规则且旧那条永远无人认领。
    func testSyncIdBackfillMintsDistinctLowercaseUUIDsAndIsIdempotent() throws {
        let directory = try makeTemporaryDirectory()
        _ = try seedV10Store(at: directory, rules: Self.sixRules)

        // ① 第一次打开：生产迁移计划跑 `migrateV10toV11`，记下六条行的 `syncId`。
        let firstOpen = try readSyncIdsAfterProductionOpen(at: directory)
        XCTAssertEqual(firstOpen.count, 6)
        XCTAssertEqual(Set(firstOpen.values).count, 6)
        for syncId in firstOpen.values {
            XCTAssertEqual(syncId, syncId.lowercased())
            XCTAssertNotNil(UUID(uuidString: syncId))
        }

        // ② 第二次打开：库已是 V11，`didMigrate` 不再被调用；在这个上下文里手工跑一遍回填
        // 闭包的等价读写，证明闭包本身幂等。
        let container = try openWithProductionMigrationPlan(at: directory)
        let context = container.mainContext
        let rules = try context.fetch(FetchDescriptor<SpaceURLRule>())
        for rule in rules where rule.syncId == nil {
            rule.syncId = UUID().uuidString.lowercased()
        }
        try context.save()

        let reread = try context.fetch(FetchDescriptor<SpaceURLRule>())
        XCTAssertEqual(reread.count, 6)
        for rule in reread {
            XCTAssertEqual(rule.syncId, firstOpen[rule.id], "rule \(rule.id) was re-minted")
        }
    }

    // MARK: - Fixtures

    private struct SeedRule {
        let id: String
        let spaceId: String
        let host: String
        let pathPrefix: String?
        let askBeforeRouting: Bool
        let sortOrder: Int
        let createdDate: Date
    }

    private struct SeededV10Store {
        let profileIds: [String]
        let spaceIds: [String]
        let tabGuids: [String]
        var tabCount: Int { tabGuids.count }
    }

    // 四条分散在两个 Space 的桶里、`sortOrder` 稠密，其中一条 `pathPrefix == nil`。
    private static let fourRules: [SeedRule] = [
        SeedRule(id: "rule-a-0", spaceId: "space-a", host: "a.example", pathPrefix: "/docs",
                 askBeforeRouting: false, sortOrder: 0, createdDate: Date(timeIntervalSince1970: 1_700_000_001)),
        SeedRule(id: "rule-a-1", spaceId: "space-a", host: "b.example", pathPrefix: nil,
                 askBeforeRouting: true, sortOrder: 1, createdDate: Date(timeIntervalSince1970: 1_700_000_002)),
        SeedRule(id: "rule-a-2", spaceId: "space-a", host: "c.example", pathPrefix: "/x/y",
                 askBeforeRouting: false, sortOrder: 2, createdDate: Date(timeIntervalSince1970: 1_700_000_003)),
        SeedRule(id: "rule-b-0", spaceId: "space-b", host: "d.example", pathPrefix: "/z",
                 askBeforeRouting: true, sortOrder: 0, createdDate: Date(timeIntervalSince1970: 1_700_000_004)),
    ]

    private static let sixRules: [SeedRule] = fourRules + [
        SeedRule(id: "rule-b-1", spaceId: "space-b", host: "e.example", pathPrefix: nil,
                 askBeforeRouting: false, sortOrder: 1, createdDate: Date(timeIntervalSince1970: 1_700_000_005)),
        SeedRule(id: "rule-b-2", spaceId: "space-b", host: "f.example", pathPrefix: "/q",
                 askBeforeRouting: false, sortOrder: 2, createdDate: Date(timeIntervalSince1970: 1_700_000_006)),
    ]

    private func makeTemporaryDirectory() throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectories.append(directory)
        return directory
    }

    /// 用显式列出的 V10 模型类型建一个真的 `ModelContainer`（形状照
    /// `PinnedTabScopeTests.seedV8Store(at:)`），写 2 个 Profile、3 个 Space、`rules` 与
    /// 3 条 tab，`save()` 后释放容器。
    @discardableResult
    private func seedV10Store(at directory: URL, rules: [SeedRule]) throws -> SeededV10Store {
        let configuration = ModelConfiguration(
            url: directory.appendingPathComponent("LocalStore.sqlite")
        )
        let container = try ModelContainer(
            for: TabDataModelSchemaV10.ProfileModel.self,
            TabDataModelSchemaV10.TabDataModel.self,
            TabDataModelSchemaV10.SpaceModel.self,
            TabDataModelSchemaV10.SpaceURLRule.self,
            TabDataModelSchemaV10.BrowserDataSettingsModel.self,
            configurations: configuration
        )
        let context = container.mainContext

        let profileIds = ["Default", "Work"]
        for profileId in profileIds {
            context.insert(TabDataModelSchemaV10.ProfileModel(profileId: profileId))
        }

        let spaceIds = ["space-a", "space-b", "space-c"]
        for (index, spaceId) in spaceIds.enumerated() {
            context.insert(TabDataModelSchemaV10.SpaceModel(
                spaceId: spaceId,
                profileId: index < 2 ? "Default" : "Work",
                name: "Space \(index)",
                colorHex: "#000000",
                iconName: "globe",
                sortOrder: index,
                createdDate: Date(timeIntervalSince1970: 1_700_000_100),
                updatedDate: Date(timeIntervalSince1970: 1_700_000_100)
            ))
        }

        let tabGuids = ["tab-0", "tab-1", "tab-2"]
        for (index, guid) in tabGuids.enumerated() {
            let tab = TabDataModelSchemaV10.TabDataModel(
                title: "Tab \(index)",
                guid: guid,
                index: index,
                url: try XCTUnwrap(URL(string: "https://tab\(index).example")),
                favicon: nil,
                createdDate: Date(timeIntervalSince1970: 1_700_000_200),
                updatedDate: Date(timeIntervalSince1970: 1_700_000_200)
            )
            tab.profileId = "Default"
            context.insert(tab)
        }

        for seed in rules {
            context.insert(TabDataModelSchemaV10.SpaceURLRule(
                id: seed.id,
                spaceId: seed.spaceId,
                host: seed.host,
                pathPrefix: seed.pathPrefix,
                askBeforeRouting: seed.askBeforeRouting,
                sortOrder: seed.sortOrder,
                createdDate: seed.createdDate
            ))
        }
        try context.save()
        return SeededV10Store(profileIds: profileIds, spaceIds: spaceIds, tabGuids: tabGuids)
    }

    /// 用生产的 `TabDataModelMigrationPlan` 与 V11 typealias 重开同一份库；模型清单逐字照
    /// `LocalStore.swift` 的 `ModelContainer(for:…)`。
    private func openWithProductionMigrationPlan(at directory: URL) throws -> ModelContainer {
        let configuration = ModelConfiguration(
            url: directory.appendingPathComponent("LocalStore.sqlite")
        )
        return try ModelContainer(
            for: TabDataModel.self,
            ProfileModel.self,
            SpaceModel.self,
            SpaceURLRule.self,
            BrowserDataSettingsModel.self,
            migrationPlan: TabDataModelMigrationPlan.self,
            configurations: configuration
        )
    }

    /// 打开一次、按 `id` 读出每条规则的 `syncId`，容器在返回前释放。
    private func readSyncIdsAfterProductionOpen(at directory: URL) throws -> [String: String] {
        let container = try openWithProductionMigrationPlan(at: directory)
        let rules = try container.mainContext.fetch(FetchDescriptor<SpaceURLRule>())
        var byId: [String: String] = [:]
        for rule in rules {
            byId[rule.id] = try XCTUnwrap(rule.syncId, "rule \(rule.id) has no syncId after migration")
        }
        return byId
    }

    // MARK: - Task 5 —— 写入口、per-row 原语、归一化、级联 origin

    private static let spaceOne = "space-1"
    private static let spaceTwo = "space-2"
    private static let spaceThree = "space-3"
    private static let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private static let t1 = Date(timeIntervalSince1970: 1_700_000_500)

    // MARK: CASE C-6 —— 唯一的对外入口真的抛，且没有 fire-and-forget 兄弟（R-M3-4a-49）

    // 防的是什么：今天的两条 replace 路径是 `performBackgroundWrite`，`writeActor == nil` 时直接
    // `return`，块内失败再被 `catch { AppLogError… }` 吞掉——「静默返回」与「成功落地」在调用方
    // 看来一模一样。留一个非抛出兄弟的实现会让调用方随时退回这条老路。
    func testApplyURLRuleEditsThrowsStoreUnavailableWhenTheStoreNeverOpened() async throws {
        // (a) 用一个同名普通文件占住 store 目录路径：`LocalStore.init` 的 `try? createDirectory`
        // 落空、`prepareStore` 的 `createDirectory` 抛 ⇒ `.failed`、`writeActor == nil`。
        let parent = try makeTemporaryDirectory()
        let blocked = parent.appendingPathComponent("localDB", isDirectory: false)
        XCTAssertTrue(FileManager.default.createFile(atPath: blocked.path, contents: Data()))
        let store = LocalStore(account: Account(userID: "test-user"),
                               storeDirectoryURL: blocked,
                               presentsCompatibilityAlerts: false)
        if case .failed = store.compatibilityStatus {
            // expected
        } else {
            XCTFail("store on a blocked path should be .failed, got \(store.compatibilityStatus)")
        }
        XCTAssertNil(store.getMainContext())

        await assertThrows(.storeUnavailable) {
            try await store.applyURLRuleEditsThrowing(
                upserts: [LocalStore.URLRuleDraft(host: "a.example", spaceId: Self.spaceOne)],
                deletedIds: []
            )
        }
    }

    func testApplyURLRuleEditsRejectsASyncIdCollisionAndLeavesEveryColumnUntouched() async throws {
        // (b) 正常 store，两条行 `A`（R1）与 `B`（R2）。
        let store = try makeStore()
        try await seed([
            RuleSeed(id: "A", spaceId: Self.spaceOne, host: "a.example", sortOrder: 0,
                     syncId: "R1", contentUpdatedDate: Self.t0),
            RuleSeed(id: "B", spaceId: Self.spaceOne, host: "b.example", sortOrder: 1,
                     syncId: "R2", contentUpdatedDate: Self.t0),
        ], in: store)
        let before = try allRows(in: store)
        XCTAssertEqual(before.count, 2)

        await assertThrows(.rowAlreadyMapped) {
            try await store.applyURLRuleEditsThrowing(
                upserts: [LocalStore.URLRuleDraft(id: "A", host: "a.example", spaceId: Self.spaceOne,
                                                  syncId: "R2")],
                deletedIds: []
            )
        }
        let after = try allRows(in: store)
        XCTAssertEqual(after, before)

        // 结构断言：`LocalStore` 上不存在非抛出的 `applyURLRuleEdits(upserts:deletedIds:)`，
        // 两条 replace 也已经不在了。
        let source = try String(contentsOf: Self.repoFile("Sources/LocalStorage/LocalStore+SpaceURLRule.swift"),
                                encoding: .utf8)
        XCTAssertFalse(source.contains("func applyURLRuleEdits("))
        XCTAssertFalse(source.contains("func replaceURLRules("))
        XCTAssertFalse(source.contains("func replaceAllURLRules("))
        XCTAssertTrue(source.contains("func applyURLRuleEditsThrowing("))
    }

    // MARK: CASE C-7 —— 只碰点名的行，只碰点名的字段

    // 防的是什么：delete-then-insert 的旧形状让每一次保存重铸全桶的 `id`；给软删行置位的实现让它对
    // 入站 tombstone 让位；不重排 `r2` 的实现在桶里留下 0/2 的空洞。(b) 防的是 insert 支拿 `nil`
    // 单元去填默认值——一条 `host` 或 `spaceId` 为空串的行会进路由表、进快照、进账户。
    func testApplyURLRuleEditsTouchesOnlyTheNamedRowsAndFields() async throws {
        let store = try makeStore()
        try await seed([
            RuleSeed(id: "r0", spaceId: Self.spaceOne, host: "r0.example", pathPrefix: "/r0",
                     sortOrder: 0, syncId: "R0", contentUpdatedDate: Self.t0),
            RuleSeed(id: "r1", spaceId: Self.spaceOne, host: "r1.example", sortOrder: 1,
                     syncId: "R1", contentUpdatedDate: Self.t0),
            RuleSeed(id: "r2", spaceId: Self.spaceOne, host: "r2.example", pathPrefix: "/r2",
                     askBeforeRouting: true, sortOrder: 2, syncId: "R2", contentUpdatedDate: Self.t0),
        ], in: store)
        let before = try allRows(in: store)
        let r0Before = try XCTUnwrap(before["r0"])

        let start = Date()
        try await store.applyURLRuleEditsThrowing(
            upserts: [LocalStore.URLRuleDraft(id: "r0",
                                              host: "changed.example",
                                              pathPrefix: r0Before.pathPrefix,
                                              askBeforeRouting: r0Before.askBeforeRouting,
                                              spaceId: Self.spaceOne,
                                              sortOrder: 0)],
            deletedIds: ["r1"]
        )
        let end = Date()

        let after = try allRows(in: store)
        XCTAssertEqual(after.count, 3, "a soft delete never removes a row")

        let r0 = try XCTUnwrap(after["r0"])
        XCTAssertEqual(r0.id, "r0")
        XCTAssertEqual(r0.syncId, "R0")
        XCTAssertEqual(r0.host, "changed.example")
        XCTAssertEqual(r0.pathPrefix, "/r0")
        assertStampedNow(r0.contentUpdatedDate, between: start, and: end)
        XCTAssertNil(r0.targetUpdatedDate)
        XCTAssertNil(r0.deletedDate)
        XCTAssertTrue(r0.pendingLocalEdit)
        XCTAssertEqual(r0.sortOrder, 0)

        let r1 = try XCTUnwrap(after["r1"])
        assertStampedNow(r1.deletedDate, between: start, and: end)
        XCTAssertFalse(r1.pendingLocalEdit, "a delete is not an edit (R-M3-4a-69)")
        XCTAssertEqual(r1.host, "r1.example")
        XCTAssertEqual(r1.syncId, "R1")
        XCTAssertEqual(r1.contentUpdatedDate, Self.t0)

        // `r2` 一个字节不动，只有 `sortOrder` 因软删留洞重编成 1（裁定 4）。
        var r2Expected = try XCTUnwrap(before["r2"])
        r2Expected.sortOrder = 1
        XCTAssertEqual(after["r2"], r2Expected)
    }

    func testInsertBranchRefusesADraftMissingAUnit() async throws {
        let store = try makeStore()
        try await seed([
            RuleSeed(id: "r0", spaceId: Self.spaceOne, host: "r0.example", sortOrder: 0, syncId: "R0"),
        ], in: store)
        let before = try allRows(in: store)

        // `content` 非 nil、`spaceId = nil`。
        await assertThrows(.noCandidateSurvived) {
            try await store.applyURLRuleEditsThrowing(
                upserts: [LocalStore.URLRuleDraft(
                    id: "fresh-1",
                    content: LocalStore.URLRuleDraft.ContentUnit(host: "x.example"),
                    spaceId: nil
                )],
                deletedIds: []
            )
        }
        // 反过来：`spaceId` 非 nil、`content = nil`。
        await assertThrows(.noCandidateSurvived) {
            try await store.applyURLRuleEditsThrowing(
                upserts: [LocalStore.URLRuleDraft(id: "fresh-2", content: nil, spaceId: Self.spaceOne)],
                deletedIds: []
            )
        }
        let after = try allRows(in: store)
        XCTAssertEqual(after, before)
        XCTAssertEqual(after.count, 1)
    }

    // MARK: CASE C-8 —— 跨桶 `id` 是一次正当的改目标（R-M3-4a-80）

    // 防的是什么：按目标 Space 桶分建索引的实现会把这次改目标判成调用方错误、抛 `rowAlreadyMapped`；
    // 走「命中不到 ⇒ 插新行」的实现更糟——同一条规则变成两条、带着同一个 `syncId`；只重排目标桶的
    // 实现在 S1 留下 0/2。
    func testRetargetKeepsIdentityAndRedensifiesBothBuckets() async throws {
        let store = try makeStore()
        try await seed(Self.twoBucketSeeds, in: store)
        let before = try allRows(in: store)

        let start = Date()
        try await store.applyURLRuleEditsThrowing(
            upserts: [LocalStore.URLRuleDraft(id: "s1-1", syncId: "R-s1-1", content: nil,
                                              spaceId: Self.spaceTwo, sortOrder: 2)],
            deletedIds: []
        )
        let end = Date()

        let after = try allRows(in: store)
        XCTAssertEqual(after.count, 5)
        let moved = try XCTUnwrap(after["s1-1"])
        XCTAssertEqual(moved.syncId, "R-s1-1")
        XCTAssertEqual(moved.spaceId, Self.spaceTwo)
        assertStampedNow(moved.targetUpdatedDate, between: start, and: end)
        XCTAssertEqual(moved.contentUpdatedDate, Self.t0)
        XCTAssertEqual(moved.host, before["s1-1"]?.host)
        XCTAssertTrue(moved.pendingLocalEdit)
        XCTAssertEqual(moved.sortOrder, 2)
        XCTAssertEqual(bucketOrder(Self.spaceOne, in: after), [0, 1])
        XCTAssertEqual(bucketOrder(Self.spaceTwo, in: after), [0, 1, 2])
        XCTAssertEqual(Set(after.values.compactMap(\.syncId)), Set(before.values.compactMap(\.syncId)))
    }

    func testRetargetAndAContentEditInOneBatchEachLandInTheirOwnBucket() async throws {
        let store = try makeStore()
        try await seed(Self.twoBucketSeeds + [
            RuleSeed(id: "s3-0", spaceId: Self.spaceThree, host: "s3.example", sortOrder: 0,
                     syncId: "R-s3-0", contentUpdatedDate: Self.t0),
        ], in: store)

        let start = Date()
        try await store.applyURLRuleEditsThrowing(
            upserts: [
                LocalStore.URLRuleDraft(id: "s1-1", syncId: "R-s1-1", content: nil,
                                        spaceId: Self.spaceTwo, sortOrder: 2),
                LocalStore.URLRuleDraft(id: "s3-0",
                                        content: LocalStore.URLRuleDraft.ContentUnit(host: "s3-new.example"),
                                        spaceId: nil),
            ],
            deletedIds: []
        )
        let end = Date()

        let after = try allRows(in: store)
        XCTAssertEqual(after.count, 6)
        let moved = try XCTUnwrap(after["s1-1"])
        XCTAssertEqual(moved.spaceId, Self.spaceTwo)
        XCTAssertEqual(moved.syncId, "R-s1-1")
        assertStampedNow(moved.targetUpdatedDate, between: start, and: end)
        XCTAssertEqual(moved.contentUpdatedDate, Self.t0)
        let edited = try XCTUnwrap(after["s3-0"])
        XCTAssertEqual(edited.host, "s3-new.example")
        XCTAssertEqual(edited.spaceId, Self.spaceThree)
        assertStampedNow(edited.contentUpdatedDate, between: start, and: end)
        XCTAssertNil(edited.targetUpdatedDate)
        XCTAssertTrue(edited.pendingLocalEdit)
        XCTAssertEqual(bucketOrder(Self.spaceOne, in: after), [0, 1])
        XCTAssertEqual(bucketOrder(Self.spaceTwo, in: after), [0, 1, 2])
        XCTAssertEqual(bucketOrder(Self.spaceThree, in: after), [0])
    }

    // MARK: CASE C-8b —— `rowAlreadyMapped` 的规则侧唯一形状是 `syncId` 撞车（R-M3-4a-80）

    // 防的是什么：只守「行已带另一个 `syncId`」而不守「这个 `syncId` 已属于另一条 `id`」的实现让两条
    // 本机行带上同一个账户身份；逐条提交（不靠 `performThrowing` 的 `rollback()`）的实现会留下半
    // 应用状态。合法的那条 upsert 排在前面，让回滚真的有东西可回。
    func testSyncIdOwnedByAnotherRowRejectsAndRollsBackTheLegitimateSibling() async throws {
        let store = try makeStore()
        try await seed([
            RuleSeed(id: "A", spaceId: Self.spaceOne, host: "a.example", sortOrder: 0,
                     syncId: "R1", contentUpdatedDate: Self.t0, targetUpdatedDate: Self.t0),
            RuleSeed(id: "B", spaceId: Self.spaceOne, host: "b.example", sortOrder: 1,
                     syncId: "R2", contentUpdatedDate: Self.t0, targetUpdatedDate: Self.t0),
        ], in: store)
        let before = try allRows(in: store)

        await assertThrows(.rowAlreadyMapped) {
            try await store.applyURLRuleEditsThrowing(
                upserts: [
                    LocalStore.URLRuleDraft(id: "B", host: "ok.example", spaceId: Self.spaceOne),
                    LocalStore.URLRuleDraft(id: "A", host: "a.example", spaceId: Self.spaceOne, syncId: "R2"),
                ],
                deletedIds: []
            )
        }
        let after = try allRows(in: store)
        XCTAssertEqual(after, before)
        XCTAssertEqual(after["B"]?.host, "b.example")
    }

    // MARK: CASE C-9 —— per-row 原语的 `syncId` 守卫与软删寻址（R-M3-4a-56 / R-M3-4a-42(a)）

    // 防的是什么：按默认读口（`deletedDate == nil` 过滤）寻址的实现会对一条软删行插出第二条同
    // `syncId` 的行；入站 tombstone 走软删的实现让跟随端的行永远清不掉；落地铸 `now` 的实现让引擎
    // 的一次写伪造出新鲜度，去赢对端一次真实的用户编辑。
    func testPerRowPrimitivesAddressSoftDeletedRowsAndNeverMintStamps() async throws {
        let store = try makeStore()
        try await seed([
            RuleSeed(id: "A", spaceId: Self.spaceOne, host: "old.example", sortOrder: 0, syncId: "R1",
                     contentUpdatedDate: Self.t0, deletedDate: Self.t0, pendingLocalEdit: true,
                     mergePartnerSyncId: "R9"),
            RuleSeed(id: "B", spaceId: Self.spaceOne, host: "b.example", sortOrder: 1, syncId: "R2",
                     contentUpdatedDate: Self.t0),
        ], in: store)
        let remoteCreated = Date(timeIntervalSince1970: 1_600_000_000)
        let remoteContent = Date(timeIntervalSince1970: 1_650_000_000)
        let remoteTarget = Date(timeIntervalSince1970: 1_660_000_000)

        // ① 命中那条软删行：不插第二条、同一次行写里清 `deletedDate` 与 `mergePartnerSyncId`、
        // 两枚戳逐字等于入参、`pendingLocalEdit` 一个字节没动。
        try await store.upsertURLRuleThrowing(syncId: "R1", spaceId: Self.spaceOne, host: "a.example",
                                              pathPrefix: nil, ask: false, sortOrder: 0,
                                              createdDate: remoteCreated,
                                              contentUpdatedDate: remoteContent,
                                              targetUpdatedDate: remoteTarget)
        let afterUpsert = try allRows(in: store)
        XCTAssertEqual(afterUpsert.count, 2)
        let a = try XCTUnwrap(afterUpsert["A"])
        XCTAssertEqual(a.syncId, "R1")
        XCTAssertNil(a.deletedDate)
        XCTAssertNil(a.mergePartnerSyncId)
        XCTAssertEqual(a.host, "a.example")
        XCTAssertEqual(a.createdDate, remoteCreated)
        XCTAssertEqual(a.contentUpdatedDate, remoteContent)
        XCTAssertEqual(a.targetUpdatedDate, remoteTarget)
        XCTAssertTrue(a.pendingLocalEdit)

        // ② 真删：那一行从库里消失。
        try await store.hardDeleteURLRuleThrowing(syncId: "R1")
        let afterDelete = try allRows(in: store)
        XCTAssertEqual(afterDelete.count, 1)
        XCTAssertNil(afterDelete["A"])
        XCTAssertEqual(afterDelete["B"], afterUpsert["B"])
        // 命中不到就静默返回（入站 tombstone 落在本机已无行的身份上）。
        try await store.hardDeleteURLRuleThrowing(syncId: "R1")
        XCTAssertEqual(try allRows(in: store).count, 1)

        // ③ 先把 `B.syncId` 换成 R3，再落一条 R2。原语只按 `syncId` 寻址（签名里没有本机
        // `id`），所以 R2 在全表命中不到 ⇒ 建行、B 一个字节不碰——见 ledger Task 5 的备注。
        try await store.performBackgroundWriteAndWaitThrowing { context in
            let rows = try context.fetch(FetchDescriptor<SpaceURLRule>(
                predicate: #Predicate { $0.id == "B" }
            ))
            for row in rows { row.syncId = "R3" }
        }
        let beforeThird = try allRows(in: store)
        XCTAssertEqual(beforeThird["B"]?.syncId, "R3")
        try await store.upsertURLRuleThrowing(syncId: "R2", spaceId: Self.spaceOne, host: "b2.example",
                                              pathPrefix: "/p", ask: true, sortOrder: 5,
                                              createdDate: remoteCreated,
                                              contentUpdatedDate: remoteContent,
                                              targetUpdatedDate: nil)
        let afterThird = try allRows(in: store)
        XCTAssertEqual(afterThird.count, 2)
        XCTAssertEqual(afterThird["B"], beforeThird["B"])
        let landedR2 = try XCTUnwrap(afterThird.values.first { $0.syncId == "R2" })
        XCTAssertEqual(landedR2.host, "b2.example")
        XCTAssertNotEqual(landedR2.id, "B")

        // ④ 从没见过的身份 ⇒ 建一条新行（R-M3-4a-42(a)，不抛 `.rowNotFound`）。
        try await store.upsertURLRuleThrowing(syncId: "R-never-seen", spaceId: Self.spaceTwo,
                                              host: " New.Example. ", pathPrefix: "/x/",
                                              ask: true, sortOrder: 0,
                                              createdDate: remoteCreated,
                                              contentUpdatedDate: remoteContent,
                                              targetUpdatedDate: remoteTarget)
        let afterFourth = try allRows(in: store)
        XCTAssertEqual(afterFourth.count, 3)
        let fresh = try XCTUnwrap(afterFourth.values.first { $0.syncId == "R-never-seen" })
        XCTAssertNotNil(UUID(uuidString: fresh.id))
        XCTAssertEqual(fresh.spaceId, Self.spaceTwo)
        XCTAssertEqual(fresh.host, "new.example")
        XCTAssertEqual(fresh.pathPrefix, "/x")
        XCTAssertTrue(fresh.askBeforeRouting)
        XCTAssertEqual(fresh.sortOrder, 0)
        XCTAssertEqual(fresh.createdDate, remoteCreated)
        XCTAssertEqual(fresh.contentUpdatedDate, remoteContent)
        XCTAssertEqual(fresh.targetUpdatedDate, remoteTarget)
        XCTAssertNil(fresh.deletedDate)
        XCTAssertNil(fresh.mergePartnerSyncId)
        XCTAssertFalse(fresh.pendingLocalEdit, "the engine's writes never raise the edit flag")
    }

    // MARK: CASE C-12 —— `syncId == nil` 的 draft 命中软删行 ⇒ 建新行（R-M3-4a-104 / 计划裁定 8）

    // 防的是什么：「不看 `deletedDate`、命中就地 upsert」的那一版把用户那次编辑写进一条隐身的行，随后
    // 那条 tombstone 的 `.applied` 把它连编辑一起硬删——「保存成功、规则消失」。反过来「命中软删行就
    // 复活」同样红：复活只走 3b。复用 `draft.id` 建新行当场违 `@Attribute(.unique)`。变体 ② 防的是
    // 把两个入口的软删语义合并：per-row 原语那一侧（C-9 ①）必须命中软删行并清 `deletedDate`。
    private static let softDeletedHitSeeds: [RuleSeed] = [
        RuleSeed(id: "I", spaceId: spaceOne, host: "old.example", sortOrder: 0, syncId: "R1",
                 contentUpdatedDate: t0, deletedDate: t1, pendingLocalEdit: false, mergePartnerSyncId: "R9"),
        RuleSeed(id: "J", spaceId: spaceOne, host: "j.example", sortOrder: 1, syncId: "RJ",
                 contentUpdatedDate: t0),
    ]

    private static func recoveryDraft(syncId: String?) -> LocalStore.URLRuleDraft {
        LocalStore.URLRuleDraft(
            id: "I",
            syncId: syncId,
            content: LocalStore.URLRuleDraft.ContentUnit(host: "new.example", pathPrefix: "/p",
                                                         askBeforeRouting: true),
            spaceId: spaceOne,
            sortOrder: 0
        )
    }

    func testEditorDraftHittingASoftDeletedRowInsertsAFreshIdentity() async throws {
        let store = try makeStore()
        try await seed(Self.softDeletedHitSeeds, in: store)
        let before = try allRows(in: store)

        try await store.applyURLRuleEditsThrowing(upserts: [Self.recoveryDraft(syncId: nil)], deletedIds: [])

        let after = try allRows(in: store)
        XCTAssertEqual(after.count, 3)
        XCTAssertEqual(after["I"], before["I"], "the soft-deleted row is not touched")
        XCTAssertEqual(after["J"], before["J"])

        let fresh = try XCTUnwrap(after.values.first { $0.id != "I" && $0.id != "J" })
        XCTAssertNotNil(UUID(uuidString: fresh.id))
        let freshSyncId = try XCTUnwrap(fresh.syncId)
        XCTAssertNotEqual(freshSyncId, "R1")
        XCTAssertNotEqual(freshSyncId, "RJ")
        XCTAssertEqual(freshSyncId, freshSyncId.lowercased())
        XCTAssertNotNil(UUID(uuidString: freshSyncId))
        XCTAssertEqual(fresh.host, "new.example")
        XCTAssertEqual(fresh.pathPrefix, "/p")
        XCTAssertTrue(fresh.askBeforeRouting)
        XCTAssertEqual(fresh.spaceId, Self.spaceOne)
        XCTAssertNil(fresh.deletedDate)
        XCTAssertNil(fresh.mergePartnerSyncId)
        XCTAssertTrue(fresh.pendingLocalEdit)
        XCTAssertNil(fresh.contentUpdatedDate, "a new row does not mint a content stamp (裁定 5)")
        XCTAssertNil(fresh.targetUpdatedDate)
        XCTAssertEqual(fresh.sortOrder, 0)
        XCTAssertEqual(bucketOrder(Self.spaceOne, in: after), [0, 1])
    }

    func testSyncCarryingDraftHittingASoftDeletedRowIsRejected() async throws {
        let store = try makeStore()
        try await seed(Self.softDeletedHitSeeds, in: store)
        let before = try allRows(in: store)

        await assertThrows(.rowAlreadyMapped) {
            try await store.applyURLRuleEditsThrowing(upserts: [Self.recoveryDraft(syncId: "R1")],
                                                      deletedIds: [])
        }
        let after = try allRows(in: store)
        XCTAssertEqual(after, before)
        XCTAssertEqual(after.count, 2)
    }

    func testEditorDraftHittingALiveRowIsAnOrdinaryUpsert() async throws {
        let store = try makeStore()
        var seeds = Self.softDeletedHitSeeds
        seeds[0].deletedDate = nil
        try await seed(seeds, in: store)

        let start = Date()
        try await store.applyURLRuleEditsThrowing(upserts: [Self.recoveryDraft(syncId: nil)], deletedIds: [])
        let end = Date()

        let after = try allRows(in: store)
        XCTAssertEqual(after.count, 2, "no new row")
        let row = try XCTUnwrap(after["I"])
        XCTAssertEqual(row.syncId, "R1")
        XCTAssertEqual(row.host, "new.example")
        assertStampedNow(row.contentUpdatedDate, between: start, and: end)
        XCTAssertTrue(row.pendingLocalEdit)
    }

    // MARK: CASE U-6 —— 归一化是不动点（R-M3-4a-21 / §8.1）

    // 防的是什么：今天的实现在解码之前剥尾斜杠，`f("/%2F") == "//"` 是一次静默的语义扩大；「先剥点再
    // trim」的分步 host 写法对 `"a. ."` 给出 `"a."`。不动点一旦不成立，每一次归一都换来一次
    // `mustRepublish` 加一次多余 commit，永不收敛。
    func testNormalizationIsAFixedPoint() {
        let hosts = ["GitHub.COM", "github.com.", "github.com..", "github.com .", "github.com ..",
                     "github.com . .", "a. .", "a. . .", " github.com. ", " *.Figma.com "]
        let paths: [String?] = ["/foo/", "/", "/foo%2F", "/%2F", "%2F", "/a%252F",
                                "/r%C3%A9sum%C3%A9", "/100%complete"]
        for host in hosts {
            for path in paths {
                assertFixedPoint(host: host, pathPrefix: path)
            }
        }

        // 200 组随机构造，确定性种子。
        var generator = SeededGenerator(seed: 0x5EED_5EED)
        let atoms = ["a", "Z", "7", ".", " ", "\n", "/", "%", "2F", "é", "中", "-"]
        for _ in 0..<200 {
            let host = (0..<Int.random(in: 0...8, using: &generator))
                .map { _ in atoms[Int.random(in: 0..<atoms.count, using: &generator)] }
                .joined()
            let path = (0..<Int.random(in: 0...8, using: &generator))
                .map { _ in atoms[Int.random(in: 0..<atoms.count, using: &generator)] }
                .joined()
            assertFixedPoint(host: host, pathPrefix: path)
        }

        // 具体值。
        XCTAssertEqual(LocalStore.normalizedPathPrefix("/%2F"), "/")
        XCTAssertEqual(LocalStore.normalizedPathPrefix("/foo%2F"), "/foo")
        XCTAssertEqual(LocalStore.normalizedPathPrefix("/a%252F"), "/a%252F")
        XCTAssertEqual(LocalStore.normalizedPathPrefix("/"), "/")
        XCTAssertEqual(LocalStore.normalizedPathPrefix("///"), "/")
        XCTAssertNil(LocalStore.normalizedPathPrefix(""))
        XCTAssertNil(LocalStore.normalizedPathPrefix(nil))
        XCTAssertEqual(LocalStore.normalizedHost("a. ."), "a")
        XCTAssertEqual(LocalStore.normalizedHost("a. . ."), "a")
        XCTAssertEqual(LocalStore.normalizedHost("github.com .."), "github.com")
        XCTAssertEqual(LocalStore.normalizedHost(" GitHub.COM. "), "github.com")
    }

    func testLocalEditAndLandingNormalizeIdentically() async throws {
        let rawHost = " GitHub.COM. "
        let rawPath = "/Foo%2F"
        let unit = LocalStore.URLRuleDraft.ContentUnit(host: rawHost, pathPrefix: rawPath)
        XCTAssertEqual(unit.host, "github.com")
        XCTAssertEqual(unit.pathPrefix, "/Foo")

        let store = try makeStore()
        try await store.applyURLRuleEditsThrowing(
            upserts: [LocalStore.URLRuleDraft(id: "via-draft", content: unit, spaceId: Self.spaceOne)],
            deletedIds: []
        )
        try await store.upsertURLRuleThrowing(syncId: "R-landed", spaceId: Self.spaceOne, host: rawHost,
                                              pathPrefix: rawPath, ask: false, sortOrder: 1,
                                              createdDate: Self.t0, contentUpdatedDate: nil,
                                              targetUpdatedDate: nil)

        let rows = try allRows(in: store)
        let viaDraft = try XCTUnwrap(rows["via-draft"])
        let landed = try XCTUnwrap(rows.values.first { $0.syncId == "R-landed" })
        XCTAssertEqual(viaDraft.host, unit.host)
        XCTAssertEqual(viaDraft.pathPrefix, unit.pathPrefix)
        XCTAssertEqual(landed.host, unit.host)
        XCTAssertEqual(landed.pathPrefix, unit.pathPrefix)
        // 扁平便利构造器也经 `ContentUnit` 转一道。
        let flat = LocalStore.URLRuleDraft(host: rawHost, pathPrefix: rawPath, spaceId: Self.spaceOne)
        XCTAssertEqual(flat.content?.host, unit.host)
        XCTAssertEqual(flat.content?.pathPrefix, unit.pathPrefix)
        XCTAssertEqual(flat.host, unit.host)
        XCTAssertEqual(flat.pathPrefix, unit.pathPrefix)
    }

    // MARK: CASE U-15e —— 改目标是搬桶，store 半边（R-M3-4a-80）

    // 防的是什么：同 C-8，外加「把 retarget 拆成 delete + insert」的实现——它换了 `syncId`，账户上那条
    // 规则的历史（两枚戳）就此断掉。
    func testSingleRetargetUpsertMovesTheRowBetweenBuckets() async throws {
        let store = try makeStore()
        try await seed(Self.twoBucketSeeds, in: store)
        let before = try allRows(in: store)

        let start = Date()
        try await store.applyURLRuleEditsThrowing(
            upserts: [LocalStore.URLRuleDraft(id: "s1-1", syncId: "R-s1-1", content: nil,
                                              spaceId: Self.spaceTwo, sortOrder: 2)],
            deletedIds: []
        )
        let end = Date()

        let after = try allRows(in: store)
        XCTAssertEqual(after.count, 5)
        XCTAssertEqual(Set(after.keys), Set(before.keys))
        let moved = try XCTUnwrap(after["s1-1"])
        XCTAssertEqual(moved.syncId, before["s1-1"]?.syncId)
        XCTAssertEqual(moved.spaceId, Self.spaceTwo)
        XCTAssertEqual(moved.contentUpdatedDate, Self.t0)
        assertStampedNow(moved.targetUpdatedDate, between: start, and: end)
        XCTAssertTrue(moved.pendingLocalEdit)
        XCTAssertEqual(bucketOrder(Self.spaceOne, in: after), [0, 1])
        XCTAssertEqual(bucketOrder(Self.spaceTwo, in: after), [0, 1, 2])
    }

    func testRetargetUpsertCarryingAnotherRowsSyncIdIsRejected() async throws {
        let store = try makeStore()
        try await seed(Self.twoBucketSeeds, in: store)
        let before = try allRows(in: store)

        await assertThrows(.rowAlreadyMapped) {
            try await store.applyURLRuleEditsThrowing(
                upserts: [LocalStore.URLRuleDraft(id: "s1-1", syncId: "R-s2-0", content: nil,
                                                  spaceId: Self.spaceTwo, sortOrder: 2)],
                deletedIds: []
            )
        }
        XCTAssertEqual(try allRows(in: store), before)
    }

    // MARK: CASE 5.置位表 —— §4.3 那张表逐行一条（R-M3-4a-11 / 48 / 65 / 69 / 72）

    // 防的是什么：「整行变了就两枚戳都盖」的实现让一次改名推进 `targetUpdatedDate`（⑤ 是它的直接
    // 探针）；把 `nil` 单元当成「写 nil / 写默认值」的实现会在 ① 里把 `spaceId` 写空、在 ② 里把
    // `host` 清掉；「只要进了 `upserts` 就置位」的实现让 ④ / ⑥ 那种无操作行也退出静止；「拖动不置位」
    // 的实现让用户的排序意图在下一次收敛里被机器写覆盖。
    private static let stampTableSeeds: [RuleSeed] = [
        RuleSeed(id: "r0", spaceId: spaceOne, host: "r0.example", pathPrefix: "/r0", sortOrder: 0,
                 syncId: "R0", contentUpdatedDate: t0, targetUpdatedDate: t0),
        RuleSeed(id: "r1", spaceId: spaceOne, host: "r1.example", pathPrefix: "/r1", sortOrder: 1,
                 syncId: "R1", contentUpdatedDate: t0, targetUpdatedDate: t0),
    ]

    private static let changedContent = LocalStore.URLRuleDraft.ContentUnit(
        host: "r0-changed.example", pathPrefix: "/r0", askBeforeRouting: false
    )

    func testStampTableContentOnlyWritesTheContentStamp() async throws {
        let store = try makeStore()
        try await seed(Self.stampTableSeeds, in: store)

        let start = Date()
        try await store.applyURLRuleEditsThrowing(
            upserts: [LocalStore.URLRuleDraft(id: "r0", content: Self.changedContent, spaceId: nil)],
            deletedIds: []
        )
        let end = Date()

        let r0 = try row("r0", in: store)
        XCTAssertEqual(r0.host, "r0-changed.example")
        assertStampedNow(r0.contentUpdatedDate, between: start, and: end)
        XCTAssertEqual(r0.targetUpdatedDate, Self.t0)
        XCTAssertEqual(r0.spaceId, Self.spaceOne)
        XCTAssertTrue(r0.pendingLocalEdit)
    }

    func testStampTableTargetOnlyWritesTheTargetStamp() async throws {
        let store = try makeStore()
        try await seed(Self.stampTableSeeds, in: store)

        let start = Date()
        try await store.applyURLRuleEditsThrowing(
            upserts: [LocalStore.URLRuleDraft(id: "r0", content: nil, spaceId: Self.spaceTwo)],
            deletedIds: []
        )
        let end = Date()

        let rows = try allRows(in: store)
        let r0 = try XCTUnwrap(rows["r0"])
        assertStampedNow(r0.targetUpdatedDate, between: start, and: end)
        XCTAssertEqual(r0.contentUpdatedDate, Self.t0)
        XCTAssertEqual(r0.host, "r0.example")
        XCTAssertEqual(r0.pathPrefix, "/r0")
        XCTAssertFalse(r0.askBeforeRouting)
        XCTAssertEqual(r0.spaceId, Self.spaceTwo)
        XCTAssertTrue(r0.pendingLocalEdit)
        XCTAssertEqual(bucketOrder(Self.spaceOne, in: rows), [0])
        XCTAssertEqual(bucketOrder(Self.spaceTwo, in: rows), [0])
    }

    func testStampTableReorderWritesNoStampButRaisesTheFlag() async throws {
        let store = try makeStore()
        try await seed(Self.stampTableSeeds, in: store)

        try await store.applyURLRuleEditsThrowing(
            upserts: [
                LocalStore.URLRuleDraft(id: "r0", content: nil, spaceId: nil, sortOrder: 1),
                LocalStore.URLRuleDraft(id: "r1", content: nil, spaceId: nil, sortOrder: 0),
            ],
            deletedIds: []
        )

        let rows = try allRows(in: store)
        let r0 = try XCTUnwrap(rows["r0"])
        let r1 = try XCTUnwrap(rows["r1"])
        XCTAssertEqual(r0.contentUpdatedDate, Self.t0)
        XCTAssertEqual(r0.targetUpdatedDate, Self.t0)
        XCTAssertEqual(r1.contentUpdatedDate, Self.t0)
        XCTAssertEqual(r1.targetUpdatedDate, Self.t0)
        XCTAssertTrue(r0.pendingLocalEdit)
        XCTAssertTrue(r1.pendingLocalEdit)
        XCTAssertEqual(r0.sortOrder, 1)
        XCTAssertEqual(r1.sortOrder, 0)
    }

    func testStampTableUnchangedUnitsAreAZeroWrite() async throws {
        let store = try makeStore()
        try await seed(Self.stampTableSeeds, in: store)
        let before = try allRows(in: store)

        try await store.applyURLRuleEditsThrowing(
            upserts: [LocalStore.URLRuleDraft(
                id: "r0",
                content: LocalStore.URLRuleDraft.ContentUnit(host: "r0.example", pathPrefix: "/r0",
                                                             askBeforeRouting: false),
                spaceId: Self.spaceOne,
                sortOrder: 0
            )],
            deletedIds: []
        )

        let after = try allRows(in: store)
        XCTAssertEqual(after, before)
        XCTAssertFalse(try XCTUnwrap(after["r0"]).pendingLocalEdit)
    }

    func testStampTableContentOnlySaveDoesNotEatARemoteRetarget() async throws {
        let store = try makeStore()
        try await seed(Self.stampTableSeeds, in: store)
        // 模拟 sheet 打开期间落地的一次远端改目标。
        try await store.performBackgroundWriteAndWaitThrowing { context in
            let rows = try context.fetch(FetchDescriptor<SpaceURLRule>(
                predicate: #Predicate { $0.id == "r0" }
            ))
            for row in rows {
                row.spaceId = Self.spaceTwo
                row.targetUpdatedDate = Self.t1
            }
        }

        let start = Date()
        try await store.applyURLRuleEditsThrowing(
            upserts: [LocalStore.URLRuleDraft(id: "r0", content: Self.changedContent, spaceId: nil)],
            deletedIds: []
        )
        let end = Date()

        let r0 = try row("r0", in: store)
        XCTAssertEqual(r0.host, "r0-changed.example")
        assertStampedNow(r0.contentUpdatedDate, between: start, and: end)
        XCTAssertEqual(r0.spaceId, Self.spaceTwo)
        XCTAssertEqual(r0.targetUpdatedDate, Self.t1)
        XCTAssertTrue(r0.pendingLocalEdit)
    }

    func testStampTableAnEmptyUpsertIsAZeroWrite() async throws {
        let store = try makeStore()
        try await seed(Self.stampTableSeeds, in: store)
        let before = try allRows(in: store)

        try await store.applyURLRuleEditsThrowing(
            upserts: [LocalStore.URLRuleDraft(id: "r0")],
            deletedIds: []
        )

        let after = try allRows(in: store)
        XCTAssertEqual(after, before)
        XCTAssertFalse(try XCTUnwrap(after["r0"]).pendingLocalEdit)
    }

    // MARK: CASE U-13 —— 用户删 Space，store 半边（R-M3-4a-24 / 41 / 85）

    // 防的是什么：把规则那一段留成 `context.delete` 的实现让行没了、`deletedDate` 无从谈起，而
    // `SpaceModel` 同批删掉 ⇒ 映射还在 ⇒ `urlrules tombstones == 0`，那些实体成为任何设备都删不掉的
    // 孤儿；按共享 body 一刀切置位的实现让这三条软删行对入站 tombstone 让位。
    func testUserIntentCascadeSoftDeletesRulesWithoutRaisingTheEditFlag() async throws {
        let store = try makeStore()
        try await seedCascadeFixture(in: store, preSoftDeletedRuleId: nil)

        let start = Date()
        store.deleteSpaceCascade(spaceId: Self.spaceOne, origin: .userIntent)
        await store.performBackgroundWriteAndWait { _ in }
        let end = Date()

        try assertSpaceAndTabsGone(in: store)
        let rows = try allRows(in: store)
        XCTAssertEqual(rows.count, 4)
        let deleted = ["s1-0", "s1-1", "s1-2"].compactMap { rows[$0] }
        XCTAssertEqual(deleted.count, 3)
        let stamps = Set(deleted.map(\.deletedDate))
        XCTAssertEqual(stamps.count, 1, "one `now` shared by the whole cascade")
        assertStampedNow(deleted[0].deletedDate, between: start, and: end)
        XCTAssertEqual(deleted.map(\.syncId), ["R-s1-0", "R-s1-1", "R-s1-2"])
        XCTAssertEqual(deleted.map(\.pendingLocalEdit), [false, false, false])
        XCTAssertNil(rows["s2-0"]?.deletedDate)
    }

    // MARK: CASE U-13c —— purge 不是删除意图，store 半边（R-M3-4a-85）

    // 防的是什么：把 purge 判成 `.userIntent`（或按共享 body 一刀切软删）的实现给这些行写上
    // `deletedDate` ⇒ §5.7 起源 (b) 成立 ⇒ 绕过两道归属门 ⇒ 一条停放在别的 Space 下、对端此刻仍然
    // 有效的规则被从账户上删掉。给 `origin` 加默认值的实现让两个入口里的哪一个漏传都编译得过。
    func testRetentionPurgeCascadeHardDeletesRules() async throws {
        let store = try makeStore()
        try await seedCascadeFixture(in: store, preSoftDeletedRuleId: "s1-2")

        try await store.deleteSpaceCascadeThrowing(spaceId: Self.spaceOne, origin: .retentionPurge)

        try assertSpaceAndTabsGone(in: store)
        let rows = try allRows(in: store)
        XCTAssertEqual(Array(rows.keys), ["s2-0"])
        XCTAssertNil(rows["s2-0"]?.deletedDate)
    }

    func testUserIntentCascadeKeepsAnEarlierSoftDeleteStamp() async throws {
        let store = try makeStore()
        try await seedCascadeFixture(in: store, preSoftDeletedRuleId: "s1-2")

        store.deleteSpaceCascade(spaceId: Self.spaceOne, origin: .userIntent)
        await store.performBackgroundWriteAndWait { _ in }

        try assertSpaceAndTabsGone(in: store)
        let rows = try allRows(in: store)
        XCTAssertEqual(rows.count, 4)
        XCTAssertNotNil(rows["s1-0"]?.deletedDate)
        XCTAssertNotNil(rows["s1-1"]?.deletedDate)
        XCTAssertEqual(rows["s1-2"]?.deletedDate, Self.t1, "an already soft-deleted row keeps its stamp")
        XCTAssertEqual(rows["s1-0"]?.deletedDate, rows["s1-1"]?.deletedDate)
        XCTAssertEqual(["s1-0", "s1-1", "s1-2"].map { rows[$0]?.pendingLocalEdit }, [false, false, false])
    }

    // MARK: CASE U-14-legacy —— 非 UUID 形的历史 `id`，store 半边（R-M3-4a-13 / 裁定 3）

    // 防的是什么：照 §4.3 第 3 条字面实现（`id` 不命中就插新行）会插出第二条带 `R1` 的行——下一轮快照
    // 两条行争同一个账户身份；把 `syncId` 兜底写成「抛 `rowAlreadyMapped`」的实现让编辑器保存这条
    // 规则时整批失败。
    func testLegacyIdIsAdoptedThroughTheSyncIdFallback() async throws {
        let store = try makeStore()
        try await seed([
            RuleSeed(id: "legacy-7", spaceId: Self.spaceOne, host: "a.example", sortOrder: 0, syncId: "R1"),
            RuleSeed(id: "n-1", spaceId: Self.spaceOne, host: "n1.example", sortOrder: 1, syncId: "RN1"),
            RuleSeed(id: "n-2", spaceId: Self.spaceOne, host: "n2.example", sortOrder: 2, syncId: "RN2"),
        ], in: store)
        let before = try allRows(in: store)
        let freshId = UUID().uuidString

        try await store.applyURLRuleEditsThrowing(
            upserts: [LocalStore.URLRuleDraft(id: freshId, host: "b.example", pathPrefix: nil,
                                              askBeforeRouting: false, spaceId: Self.spaceOne,
                                              syncId: "R1")],
            deletedIds: []
        )

        let after = try allRows(in: store)
        XCTAssertEqual(after.count, 3)
        XCTAssertNil(after["legacy-7"])
        let adopted = try XCTUnwrap(after[freshId])
        XCTAssertEqual(adopted.syncId, "R1")
        XCTAssertEqual(adopted.host, "b.example")
        XCTAssertEqual(adopted.sortOrder, 0)
        XCTAssertEqual(after["n-1"], before["n-1"])
        XCTAssertEqual(after["n-2"], before["n-2"])
        XCTAssertEqual(bucketOrder(Self.spaceOne, in: after), [0, 1, 2])
    }

    // MARK: - Task 8 —— 落地批次入口、`AccountPhiURLRuleAccess`、落地后的读、`urlRuleChangesPublisher`

    // MARK: CASE U-10 —— owner 变化不换身份，两桶都重排（R-M3-4a-3 / R-M3-4a-51）

    // 防的是什么：把 rehome 做成「删旧行 + 插新行」会换掉 `id` 与 `syncId`，下一轮差分把旧身份判成本机
    // 删除并发一条 tombstone；只重排一个桶会在源桶留下一个空洞下标，而 `sortOrder` 是 `Specificity`
    // 的第三项。
    func testSyncMoveRehomesTheRowKeepingIdentityAndDensifiesBothBuckets() async throws {
        let store = try makeStore()
        try await seed(Self.twoBucketSeeds, in: store)
        let before = try allRows(in: store)

        let values = landing("R-s1-0", spaceId: Self.spaceTwo, host: "s1-0.example", sortOrder: 0)
        let batch = URLRuleApplyBatch(unordered: [.move(values)],
                                      currentSpaceIds: ["R-s1-0": Self.spaceOne])
        try await store.applyURLRuleSyncBatchThrowing(batch.ops)

        let after = try allRows(in: store)
        XCTAssertEqual(after.count, 5, "no second row for R-s1-0")
        XCTAssertEqual(Set(after.keys), Set(before.keys))
        XCTAssertEqual(after.values.filter { $0.syncId == "R-s1-0" }.count, 1)
        let moved = try XCTUnwrap(after["s1-0"])
        XCTAssertEqual(moved.id, "s1-0")
        XCTAssertEqual(moved.syncId, "R-s1-0")
        XCTAssertEqual(moved.spaceId, Self.spaceTwo)
        XCTAssertEqual(moved.createdDate, before["s1-0"]?.createdDate)
        XCTAssertFalse(moved.pendingLocalEdit, "engine writes never raise the edit flag")
        XCTAssertEqual(bucketOrder(Self.spaceOne, in: after), [0, 1])
        XCTAssertEqual(bucketOrder(Self.spaceTwo, in: after), [0, 1, 2])
    }

    // MARK: CASE U-10b —— 纯重排不得被翻译成 rehome（真库半边）

    // 防的是什么：把 `.move` 一律当 rehome 的实现会白重排一个这一页根本没被碰过的桶——一次无意义的
    // 写经 §6.5 的 publisher 变成一次多余的推送轮，稳态 `pushed == 0` 当场破。
    func testDemotedReorderTouchesOnlyItsOwnBucket() async throws {
        let store = try makeStore()
        try await seed(Self.twoBucketSeeds, in: store)
        let before = try allRows(in: store)

        let values = landing("R-s1-0", spaceId: Self.spaceOne, host: "s1-0.example", sortOrder: 2)
        let batch = URLRuleApplyBatch(unordered: [.move(values)],
                                      currentSpaceIds: ["R-s1-0": Self.spaceOne])
        XCTAssertEqual(batch.ops, [.reorder(syncId: "R-s1-0", spaceId: Self.spaceOne, sortOrder: 2)])
        try await store.applyURLRuleSyncBatchThrowing(batch.ops)

        let after = try allRows(in: store)
        XCTAssertEqual(after.count, 5)
        for id in ["s2-0", "s2-1"] {
            XCTAssertEqual(after[id], before[id], "the untouched bucket must not be written (\(id))")
        }
        let reordered = try XCTUnwrap(after["s1-0"])
        XCTAssertEqual(reordered.spaceId, Self.spaceOne)
        XCTAssertEqual(reordered.host, before["s1-0"]?.host)
        XCTAssertEqual(reordered.contentUpdatedDate, before["s1-0"]?.contentUpdatedDate)
        XCTAssertEqual(reordered.targetUpdatedDate, before["s1-0"]?.targetUpdatedDate)
        XCTAssertEqual(bucketOrder(Self.spaceOne, in: after), [0, 1, 2])
    }

    // MARK: CASE U-10c —— 改目标到 Incognito：写的是裸前缀常量

    // 防的是什么：把保留常量解析成某个活的 incognito 运行期 id 会让这条规则在下次启动后变成死目标
    // （`isRoutableRuleTarget` 对它返回 false）。
    func testSyncMoveToTheIncognitoTargetWritesTheBarePrefix() async throws {
        let store = try makeStore()
        try await seed(Self.twoBucketSeeds, in: store)
        let before = try allRows(in: store)

        let values = landing("R-s1-0", spaceId: SpaceManager.incognitoRuleTargetId,
                             host: "s1-0.example", sortOrder: 0)
        let batch = URLRuleApplyBatch(unordered: [.move(values)],
                                      currentSpaceIds: ["R-s1-0": Self.spaceOne])
        try await store.applyURLRuleSyncBatchThrowing(batch.ops)

        let after = try allRows(in: store)
        let moved = try XCTUnwrap(after["s1-0"])
        XCTAssertEqual(moved.spaceId, "space.incognito")
        XCTAssertEqual(moved.spaceId, SpaceManager.incognitoRuleTargetId)
        XCTAssertFalse(moved.spaceId.hasPrefix("space.incognito."), "never a runtime Incognito id")
        XCTAssertEqual(moved.syncId, before["s1-0"]?.syncId)
        XCTAssertEqual(moved.id, before["s1-0"]?.id)
        XCTAssertEqual(moved.createdDate, before["s1-0"]?.createdDate)
        XCTAssertEqual(bucketOrder(Self.spaceOne, in: after), [0, 1])
        XCTAssertEqual(bucketOrder(SpaceManager.incognitoRuleTargetId, in: after), [0])
    }

    // MARK: CASE U-10d —— Incognito 改回 Space：两个桶各重排一次

    // 防的是什么：把保留常量那个桶当成「不是真桶」跳过的实现会在 incognito 桶里留下空洞。
    func testSyncMoveFromIncognitoBackToASpaceDensifiesBothBuckets() async throws {
        let store = try makeStore()
        let incognito = SpaceManager.incognitoRuleTargetId
        try await seed(Self.twoBucketSeeds + [
            RuleSeed(id: "inc-0", spaceId: incognito, host: "inc-0.example", sortOrder: 0, syncId: "R-inc-0"),
            RuleSeed(id: "inc-1", spaceId: incognito, host: "inc-1.example", sortOrder: 1, syncId: "R-inc-1"),
            RuleSeed(id: "inc-2", spaceId: incognito, host: "inc-2.example", sortOrder: 2, syncId: "R-inc-2"),
        ], in: store)

        let values = landing("R-inc-1", spaceId: Self.spaceTwo, host: "inc-1.example", sortOrder: 1)
        let batch = URLRuleApplyBatch(unordered: [.move(values)],
                                      currentSpaceIds: ["R-inc-1": incognito])
        try await store.applyURLRuleSyncBatchThrowing(batch.ops)

        let after = try allRows(in: store)
        XCTAssertEqual(after.count, 8)
        let moved = try XCTUnwrap(after["inc-1"])
        XCTAssertEqual(moved.id, "inc-1")
        XCTAssertEqual(moved.syncId, "R-inc-1")
        XCTAssertEqual(moved.spaceId, Self.spaceTwo)
        XCTAssertEqual(bucketOrder(incognito, in: after), [0, 1])
        XCTAssertEqual(bucketOrder(Self.spaceTwo, in: after), [0, 1, 2])
        XCTAssertEqual(bucketOrder(Self.spaceOne, in: after), [0, 1, 2], "S1 was not touched")
    }

    // MARK: CASE U-10e ② —— 一身份一页一次写，真库半边

    func testMergedMoveAndUpdateLandsOnceWithBothBucketsDense() async throws {
        let store = try makeStore()
        try await seed(Self.twoBucketSeeds, in: store)

        let values = landing("R-s1-1", spaceId: Self.spaceTwo, host: "new.example", sortOrder: 0)
        let batch = URLRuleApplyBatch(unordered: [.move(values), .update(values)],
                                      currentSpaceIds: ["R-s1-1": Self.spaceOne])
        XCTAssertEqual(batch.ops.count, 1)
        try await store.applyURLRuleSyncBatchThrowing(batch.ops)

        let after = try allRows(in: store)
        XCTAssertEqual(after.count, 5)
        XCTAssertEqual(after.values.filter { $0.syncId == "R-s1-1" }.count, 1)
        let moved = try XCTUnwrap(after["s1-1"])
        XCTAssertEqual(moved.host, "new.example", "the update's content group must not be lost")
        XCTAssertEqual(moved.spaceId, Self.spaceTwo)
        XCTAssertEqual(bucketOrder(Self.spaceOne, in: after), [0, 1])
        XCTAssertEqual(bucketOrder(Self.spaceTwo, in: after), [0, 1, 2])
    }

    // MARK: CASE U-10f —— 行不存在时按载荷建行（R-M3-4a-42(a) / R-M3-4a-56）

    // 防的是什么：抛 `rowNotFound` 的实现会让整批永久重试；按 `allURLRules()`（过滤软删）判定「行不
    // 存在」的实现会插进第二条同 `syncId` 的行——`.unique` 只建在 `id` 上，数据库不会挡。
    func testUpdateForAnUnknownIdentityCreatesTheRowFromThePayload() async throws {
        let store = try makeStore()
        try await seed(Self.twoBucketSeeds, in: store)
        let created = Date(timeIntervalSince1970: 0.300)

        let values = landing("R9", spaceId: Self.spaceOne, host: "r9.example", pathPrefix: "/docs",
                             ask: true, sortOrder: 1, createdDate: created)
        try await store.applyURLRuleSyncBatchThrowing([.update(values)])

        let after = try allRows(in: store)
        XCTAssertEqual(after.count, 6)
        let rows = after.values.filter { $0.syncId == "R9" }
        XCTAssertEqual(rows.count, 1)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.host, "r9.example")
        XCTAssertEqual(row.pathPrefix, "/docs")
        XCTAssertTrue(row.askBeforeRouting)
        XCTAssertEqual(row.spaceId, Self.spaceOne)
        XCTAssertEqual(row.createdDate, created)
        XCTAssertNil(row.deletedDate)
        XCTAssertFalse(row.pendingLocalEdit)
        XCTAssertEqual(bucketOrder(Self.spaceOne, in: after), [0, 1, 2, 3])
    }

    func testUpdateHittingASoftDeletedRowRevivesItInPlaceWithoutASecondRow() async throws {
        let store = try makeStore()
        try await seed(Self.twoBucketSeeds + [
            RuleSeed(id: "s1-9", spaceId: Self.spaceOne, host: "s1-9.example", sortOrder: 9, syncId: "R-s1-9",
                     deletedDate: Self.t1, mergePartnerSyncId: "R-s1-0"),
        ], in: store)

        let values = landing("R-s1-9", spaceId: Self.spaceOne, host: "revived.example", sortOrder: 3)
        try await store.applyURLRuleSyncBatchThrowing([.update(values)])

        let after = try allRows(in: store)
        XCTAssertEqual(after.count, 6, "no second row for R-s1-9")
        XCTAssertEqual(after.values.filter { $0.syncId == "R-s1-9" }.count, 1)
        let revived = try XCTUnwrap(after["s1-9"])
        XCTAssertNil(revived.deletedDate)
        XCTAssertNil(revived.mergePartnerSyncId)
        XCTAssertEqual(revived.host, "revived.example")
        XCTAssertFalse(revived.pendingLocalEdit)
        XCTAssertEqual(bucketOrder(Self.spaceOne, in: after), [0, 1, 2, 3])
    }

    // MARK: CASE U-16 —— 稠密 `sortOrder` 的收尾重排，含无身份行与停放行（R-M3-4a-3 / §8.3）

    // 防的是什么：只重排「本轮参与同步的那几条」会让被排除的兄弟留着旧下标并与新写的撞上。
    func testTrailingDensificationRenumbersEveryLiveRowInTheBucket() async throws {
        let store = try makeStore()
        try await seed([
            RuleSeed(id: "p0", spaceId: Self.spaceOne, host: "p0.example", sortOrder: 0, syncId: "R-p0"),
            RuleSeed(id: "p1", spaceId: Self.spaceOne, host: "p1.example", sortOrder: 3, syncId: "R-p1"),
            // 从没上过账户。
            RuleSeed(id: "u2", spaceId: Self.spaceOne, host: "u2.example", sortOrder: 3, syncId: nil),
            // 对应游标停放中：行在库里，同步侧这一轮不碰它。
            RuleSeed(id: "p3", spaceId: Self.spaceOne, host: "p3.example", sortOrder: 7, syncId: "R-p3"),
            RuleSeed(id: "p4", spaceId: Self.spaceOne, host: "p4.example", sortOrder: 9, syncId: "R-p4"),
            RuleSeed(id: "s2-0", spaceId: Self.spaceTwo, host: "s2-0.example", sortOrder: 4, syncId: "R-s2-0"),
        ], in: store)

        try await store.applyURLRuleSyncBatchThrowing(
            [.reorder(syncId: "R-p0", spaceId: Self.spaceOne, sortOrder: 0)]
        )

        let after = try allRows(in: store)
        let bucket = ["p0", "p1", "u2", "p3", "p4"].compactMap { after[$0] }
        XCTAssertEqual(bucket.count, 5)
        XCTAssertEqual(bucket.map(\.sortOrder), [0, 1, 2, 3, 4],
                       "a full permutation in the pre-landing (sortOrder, id) order")
        XCTAssertEqual(after["s2-0"]?.sortOrder, 4, "an untouched bucket keeps its values")
    }

    // MARK: CASE U-26 —— 落地写远端戳，两个都写，一枚 `now` 都不铸（R-M3-4a-20 / R-M3-4a-48）

    // 防的是什么：落地铸 `now` 会让跟随端那两列严格新于账户上的戳；一旦游标文件报损触发整类型重放，
    // 它就以伪造的戳首发并赢下作者真正的编辑。两个戳只写一个的实现在第二段红。
    func testLandingWritesBothRemoteStampsAndNeverNow() async throws {
        let store = try makeStore()
        try await seed(Self.twoBucketSeeds, in: store)

        let values = landing("R7", spaceId: Self.spaceOne, host: "r7.example", sortOrder: 3,
                             createdDate: Date(timeIntervalSince1970: 0.300),
                             contentUpdatedDate: Date(timeIntervalSince1970: 0.500),
                             targetUpdatedDate: Date(timeIntervalSince1970: 0.700))
        try await store.applyURLRuleSyncBatchThrowing([.create(values)])

        let created = try XCTUnwrap(try allRows(in: store).values.first { $0.syncId == "R7" })
        XCTAssertEqual(milliseconds(created.createdDate), 300)
        XCTAssertEqual(milliseconds(created.contentUpdatedDate), 500)
        XCTAssertEqual(milliseconds(created.targetUpdatedDate), 700)
        let wallClock = Date()
        XCTAssertLessThan(created.createdDate, wallClock.addingTimeInterval(-86_400))
        XCTAssertLessThan(try XCTUnwrap(created.contentUpdatedDate), wallClock.addingTimeInterval(-86_400))
        XCTAssertLessThan(try XCTUnwrap(created.targetUpdatedDate), wallClock.addingTimeInterval(-86_400))

        // 第二段：只改内容的 `.update`，内容组戳 900、目标戳仍 700。
        let contentOnly = landing("R7", spaceId: Self.spaceOne, host: "r7-edited.example", sortOrder: 3,
                                  createdDate: Date(timeIntervalSince1970: 0.300),
                                  contentUpdatedDate: Date(timeIntervalSince1970: 0.900),
                                  targetUpdatedDate: Date(timeIntervalSince1970: 0.700))
        try await store.applyURLRuleSyncBatchThrowing([.update(contentOnly)])

        let updated = try XCTUnwrap(try allRows(in: store).values.first { $0.syncId == "R7" })
        XCTAssertEqual(updated.id, created.id)
        XCTAssertEqual(updated.host, "r7-edited.example")
        XCTAssertEqual(milliseconds(updated.contentUpdatedDate), 900)
        XCTAssertEqual(milliseconds(updated.targetUpdatedDate), 700, "target stamp untouched")
        XCTAssertEqual(milliseconds(updated.createdDate), 300)
    }

    // MARK: CASE U-24 —— 落地之后的刷新读的是已提交的表（R-M3-4a-34 / R-M3-4a-49）

    // 防的是什么：批次入口若走 `performBackgroundWrite`（返回时事务还没提交），紧跟其后的重新 fetch
    // 读到的是旧值。先读一次让主上下文登记这几行（`SpaceManager.cachedURLRules` 持的正是它们），
    // 再断言 `await` 返回后**立刻**读到新值。
    func testReadRightAfterLandingSeesTheCommittedTable() async throws {
        let store = try makeStore()
        try await seed(Self.twoBucketSeeds + [
            RuleSeed(id: "s1-9", spaceId: Self.spaceOne, host: "s1-9.example", sortOrder: 9, syncId: "R-s1-9",
                     deletedDate: Self.t1),
        ], in: store)
        let registered = store.getAllURLRules()
        XCTAssertEqual(registered.first { $0.id == "s1-0" }?.host, "s1-0.example")

        let values = landing("R-s1-0", spaceId: Self.spaceOne, host: "new.example", sortOrder: 0)
        try await store.applyURLRuleSyncBatchThrowing([.update(values)])
        let rules = store.getAllURLRules()

        XCTAssertEqual(rules.first { $0.id == "s1-0" }?.host, "new.example")
        XCTAssertFalse(rules.contains { $0.id == "s1-9" }, "soft-deleted rows stay filtered")
    }

    // MARK: CASE U-24b —— 编辑器写面的刷新同样看见已提交的表

    func testReadRightAfterAnEditorWriteSeesTheCommittedTable() async throws {
        let store = try makeStore()
        try await seed(Self.twoBucketSeeds, in: store)
        _ = store.getAllURLRules()

        try await store.applyURLRuleEditsThrowing(
            upserts: [LocalStore.URLRuleDraft(id: "s1-0", syncId: "R-s1-0",
                                              content: LocalStore.URLRuleDraft.ContentUnit(host: "new.example"),
                                              spaceId: nil, sortOrder: nil)],
            deletedIds: []
        )
        let rules = store.getAllURLRules()
        XCTAssertEqual(rules.first { $0.id == "s1-0" }?.host, "new.example")
    }

    // MARK: CASE U-24c —— agent 三个写面共用同一块地板（新增 / 改 host / 删）

    func testAgentWriteFacesShareTheCommittedFloorAndSoftDeleteStaysVisibleToSync() async throws {
        let store = try makeStore()
        try await seed(Self.twoBucketSeeds, in: store)
        _ = store.getAllURLRules()

        try await store.applyURLRuleEditsThrowing(
            upserts: [LocalStore.URLRuleDraft(id: "new-1", host: "added.example", spaceId: Self.spaceOne)],
            deletedIds: []
        )
        XCTAssertTrue(store.getAllURLRules().contains { $0.id == "new-1" })

        try await store.applyURLRuleEditsThrowing(
            upserts: [LocalStore.URLRuleDraft(id: "new-1", content: LocalStore.URLRuleDraft.ContentUnit(host: "changed.example"),
                                              spaceId: nil, sortOrder: nil)],
            deletedIds: []
        )
        XCTAssertEqual(store.getAllURLRules().first { $0.id == "new-1" }?.host, "changed.example")

        try await store.applyURLRuleEditsThrowing(upserts: [], deletedIds: ["new-1"])
        XCTAssertFalse(store.getAllURLRules().contains { $0.id == "new-1" }, "soft-deleted ⇒ filtered")
        let unfiltered = try allRows(in: store)
        XCTAssertNotNil(unfiltered["new-1"]?.deletedDate, "still in the unfiltered domain")
        let access = AccountPhiURLRuleAccess(store: store)
        XCTAssertNotNil(try access.allURLRulesIncludingDeleted().first { $0.id == "new-1" }?.deletedDate)
        XCTAssertFalse(try access.allURLRules().contains { $0.id == "new-1" })
    }

    // MARK: CASE U-24d —— Space 集合变化也要刷新，真库半边（R-M3-4a-50 第 6 行）

    func testUserIntentCascadeHidesTheSpacesRulesFromTheDefaultRead() async throws {
        let store = try makeStore()
        try await seed(Self.twoBucketSeeds, in: store)
        _ = store.getAllURLRules()

        try await store.deleteSpaceCascadeThrowing(spaceId: Self.spaceTwo, origin: .userIntent)
        let rules = store.getAllURLRules()

        XCTAssertFalse(rules.contains { $0.spaceId == Self.spaceTwo })
        XCTAssertEqual(rules.count, 3)
        let unfiltered = try allRows(in: store)
        XCTAssertEqual(unfiltered.values.filter { $0.spaceId == Self.spaceTwo && $0.deletedDate != nil }.count, 2)
    }

    // MARK: `AccountPhiURLRuleAccess` —— 两个读口、缓存读者、`liveOwners`、`apply` 之后的重读

    func testAccountAccessReadsFilterSoftDeletedRowsAndApplyRebuildsTheSnapshot() async throws {
        let store = try makeStore()
        try await seed(Self.twoBucketSeeds + [
            RuleSeed(id: "s1-9", spaceId: Self.spaceOne, host: "s1-9.example", sortOrder: 9, syncId: "R-s1-9",
                     deletedDate: Self.t1),
        ], in: store)
        let access = AccountPhiURLRuleAccess(store: store)

        let live = try access.allURLRules()
        XCTAssertEqual(live.map(\.id), ["s1-0", "s1-1", "s1-2", "s2-0", "s2-1"], "(spaceId, sortOrder, id)")
        let all = try access.allURLRulesIncludingDeleted()
        XCTAssertEqual(all.count, 6)
        XCTAssertNotNil(all.first { $0.id == "s1-9" }?.deletedDate)
        XCTAssertEqual(access.siblings(inSpaceId: Self.spaceOne).map(\.id), ["s1-0", "s1-1", "s1-2"])
        XCTAssertTrue(access.isKnownLocalURLRule("R-s1-0"))
        XCTAssertFalse(access.isKnownLocalURLRule("R-s1-9"), "soft-deleted rows are not known")
        XCTAssertFalse(access.isKnownLocalURLRule("s1-0"), "the predicate is on syncId, not id")
        let owners = try access.liveOwners(["R-s1-0", "R-s1-9", "R-none"])
        XCTAssertEqual(owners.claimed, ["R-s1-0"])
        XCTAssertTrue(owners.owners.isEmpty)

        let values = landing("R-s1-0", spaceId: Self.spaceOne, host: "new.example", sortOrder: 0)
        try await access.apply(URLRuleApplyBatch(unordered: [.update(values)],
                                                 currentSpaceIds: ["R-s1-0": Self.spaceOne]))
        XCTAssertEqual(access.siblings(inSpaceId: Self.spaceOne).first?.host, "new.example",
                       "apply rebuilds the page snapshot")
    }

    // MARK: CASE U-8p —— store 级变化信号：塌缩成一次、订阅当刻不发、软删也发（§6.5 / R-M3-4a-51）

    // 防的是什么：不塌缩时一次 30 条的落地会排 30 轮推送；seed 当前值会让每次挂订阅都凭空多一轮；
    // 值快照建在过滤后的定义域上时一次软删（本机删除意图的全部载体）会被吞掉。软删的是桶尾那条，
    // 于是这次写除了 `deletedDate` 之外一个字节都没改。
    func testURLRuleChangesPublisherCollapsesBurstsDoesNotSeedAndEmitsForSoftDeletes() async throws {
        let store = try makeStore()
        var received = 0
        let cancellable = store.urlRuleChangesPublisher(debounceWindow: Self.shortDebounceWindow)
            .sink { _ in received += 1 }
        defer { cancellable.cancel() }

        waitPastDebounceWindow(Self.shortDebounceWindow)
        let afterQuietPeriod = received
        XCTAssertEqual(afterQuietPeriod, 0, "订阅当刻不发当前值")

        for index in 0..<30 {
            try await store.applyURLRuleEditsThrowing(
                upserts: [LocalStore.URLRuleDraft(id: "burst-\(index)", host: "burst-\(index).example",
                                                  spaceId: Self.spaceOne)],
                deletedIds: []
            )
        }
        waitPastDebounceWindow(Self.shortDebounceWindow)
        let afterBurst = received
        XCTAssertEqual(afterBurst, 1, "30 次写入在防抖窗口里塌成一次")

        try await store.applyURLRuleEditsThrowing(upserts: [], deletedIds: ["burst-29"])
        waitPastDebounceWindow(Self.shortDebounceWindow)
        let afterSoftDelete = received
        XCTAssertEqual(afterSoftDelete, 2, "a soft delete is a change the diff must see")
    }

    // MARK: - Task 8 fixtures

    private static let shortDebounceWindow: TimeInterval = 0.2

    /// 落地载荷；三枚戳默认 `t0`，用例要钉戳时自己传。
    private func landing(_ syncId: String, spaceId: String, host: String, pathPrefix: String? = nil,
                         ask: Bool = false, sortOrder: Int,
                         createdDate: Date = LocalStoreURLRuleThrowingTests.t0,
                         contentUpdatedDate: Date = LocalStoreURLRuleThrowingTests.t0,
                         targetUpdatedDate: Date = LocalStoreURLRuleThrowingTests.t0) -> URLRuleLandingValues {
        URLRuleLandingValues(syncId: syncId, spaceId: spaceId, host: host, pathPrefix: pathPrefix,
                             askBeforeRouting: ask, sortOrder: sortOrder, createdDate: createdDate,
                             contentUpdatedDate: contentUpdatedDate, targetUpdatedDate: targetUpdatedDate)
    }

    private func milliseconds(_ date: Date?) -> Int? {
        date.map { Int(($0.timeIntervalSince1970 * 1_000).rounded()) }
    }

    /// 跑过给定的防抖窗口再多留一点，让主队列上的投递有机会落地（照 `LocalStoreBookmarkThrowingTests`）。
    private func waitPastDebounceWindow(_ window: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(window + 0.6))
    }

    // MARK: - Task 5 fixtures

    /// 一条行的十三列，落进写块里再建 `SpaceURLRule`（`@Model` 实例不跨上下文）。
    private struct RuleSeed {
        var id: String
        var spaceId: String
        var host: String
        var pathPrefix: String? = nil
        var askBeforeRouting: Bool = false
        var sortOrder: Int
        var createdDate: Date = Date(timeIntervalSince1970: 1_690_000_000)
        var syncId: String? = nil
        var contentUpdatedDate: Date? = nil
        var targetUpdatedDate: Date? = nil
        var deletedDate: Date? = nil
        var pendingLocalEdit: Bool = false
        var mergePartnerSyncId: String? = nil
    }

    /// 一条行十三列的值快照，读自 `getMainContext()` 的全表 fetch（含软删行）。
    private struct RuleRow: Equatable {
        var id: String
        var spaceId: String
        var host: String
        var pathPrefix: String?
        var askBeforeRouting: Bool
        var sortOrder: Int
        var createdDate: Date
        var syncId: String?
        var contentUpdatedDate: Date?
        var targetUpdatedDate: Date?
        var deletedDate: Date?
        var pendingLocalEdit: Bool
        var mergePartnerSyncId: String?

        init(_ rule: SpaceURLRule) {
            id = rule.id
            spaceId = rule.spaceId
            host = rule.host
            pathPrefix = rule.pathPrefix
            askBeforeRouting = rule.askBeforeRouting
            sortOrder = rule.sortOrder
            createdDate = rule.createdDate
            syncId = rule.syncId
            contentUpdatedDate = rule.contentUpdatedDate
            targetUpdatedDate = rule.targetUpdatedDate
            deletedDate = rule.deletedDate
            pendingLocalEdit = rule.pendingLocalEdit
            mergePartnerSyncId = rule.mergePartnerSyncId
        }
    }

    // S1 三条（0/1/2）、S2 两条（0/1），五条都带 `syncId` 与固定的 `contentUpdatedDate`。
    private static let twoBucketSeeds: [RuleSeed] = [
        RuleSeed(id: "s1-0", spaceId: spaceOne, host: "s1-0.example", sortOrder: 0, syncId: "R-s1-0",
                 contentUpdatedDate: t0),
        RuleSeed(id: "s1-1", spaceId: spaceOne, host: "s1-1.example", sortOrder: 1, syncId: "R-s1-1",
                 contentUpdatedDate: t0),
        RuleSeed(id: "s1-2", spaceId: spaceOne, host: "s1-2.example", sortOrder: 2, syncId: "R-s1-2",
                 contentUpdatedDate: t0),
        RuleSeed(id: "s2-0", spaceId: spaceTwo, host: "s2-0.example", sortOrder: 0, syncId: "R-s2-0",
                 contentUpdatedDate: t0),
        RuleSeed(id: "s2-1", spaceId: spaceTwo, host: "s2-1.example", sortOrder: 1, syncId: "R-s2-1",
                 contentUpdatedDate: t0),
    ]

    private func makeStore() throws -> LocalStore {
        let directory = try makeTemporaryDirectory()
        return LocalStore(account: Account(userID: "test-user"),
                          storeDirectoryURL: directory,
                          presentsCompatibilityAlerts: false)
    }

    private func seed(_ seeds: [RuleSeed], in store: LocalStore) async throws {
        try await store.performBackgroundWriteAndWaitThrowing { context in
            for seed in seeds {
                context.insert(SpaceURLRule(
                    id: seed.id,
                    spaceId: seed.spaceId,
                    host: seed.host,
                    pathPrefix: seed.pathPrefix,
                    askBeforeRouting: seed.askBeforeRouting,
                    sortOrder: seed.sortOrder,
                    createdDate: seed.createdDate,
                    syncId: seed.syncId,
                    contentUpdatedDate: seed.contentUpdatedDate,
                    targetUpdatedDate: seed.targetUpdatedDate,
                    deletedDate: seed.deletedDate,
                    pendingLocalEdit: seed.pendingLocalEdit,
                    mergePartnerSyncId: seed.mergePartnerSyncId
                ))
            }
        }
    }

    /// U-13 / U-13c 的现场：S1 一行 `SpaceModel`、两条 S1 的 `TabDataModel`（另一条 S2 的做对照）、
    /// S1 三条规则（`pendingLocalEdit = false`）、S2 一条对照规则。
    private func seedCascadeFixture(in store: LocalStore, preSoftDeletedRuleId: String?) async throws {
        try await store.performBackgroundWriteAndWaitThrowing { context in
            context.insert(SpaceModel(spaceId: Self.spaceOne, profileId: "Default", name: "One",
                                      colorHex: "#000000", iconName: "globe", sortOrder: 0))
            for (index, spaceId) in [Self.spaceOne, Self.spaceOne, Self.spaceTwo].enumerated() {
                let tab = TabDataModel(title: "Tab \(index)", guid: "tab-\(index)", index: index,
                                       url: URL(string: "https://tab\(index).example")!, favicon: nil,
                                       createdDate: Self.t0, updatedDate: Self.t0)
                tab.profileId = "Default"
                tab.spaceId = spaceId
                context.insert(tab)
            }
        }
        var seeds: [RuleSeed] = [
            RuleSeed(id: "s1-0", spaceId: Self.spaceOne, host: "s1-0.example", sortOrder: 0, syncId: "R-s1-0"),
            RuleSeed(id: "s1-1", spaceId: Self.spaceOne, host: "s1-1.example", sortOrder: 1, syncId: "R-s1-1"),
            RuleSeed(id: "s1-2", spaceId: Self.spaceOne, host: "s1-2.example", sortOrder: 2, syncId: "R-s1-2"),
            RuleSeed(id: "s2-0", spaceId: Self.spaceTwo, host: "s2-0.example", sortOrder: 0, syncId: "R-s2-0"),
        ]
        if let preSoftDeletedRuleId {
            for index in seeds.indices where seeds[index].id == preSoftDeletedRuleId {
                seeds[index].deletedDate = Self.t1
            }
        }
        try await seed(seeds, in: store)
    }

    private func assertSpaceAndTabsGone(in store: LocalStore,
                                        file: StaticString = #filePath,
                                        line: UInt = #line) throws {
        drainMainQueue()
        let context = try XCTUnwrap(store.getMainContext())
        let spaceOne = Self.spaceOne
        let spaces = try context.fetch(FetchDescriptor<SpaceModel>(
            predicate: #Predicate { $0.spaceId == spaceOne }
        ))
        XCTAssertTrue(spaces.isEmpty, "SpaceModel row survived the cascade", file: file, line: line)
        let tabs = try context.fetch(FetchDescriptor<TabDataModel>())
        XCTAssertEqual(tabs.map(\.guid), ["tab-2"], "only the S2 tab survives", file: file, line: line)
    }

    private func allRows(in store: LocalStore) throws -> [String: RuleRow] {
        drainMainQueue()
        let context = try XCTUnwrap(store.getMainContext())
        let rows = try context.fetch(FetchDescriptor<SpaceURLRule>())
        return Dictionary(uniqueKeysWithValues: rows.map { ($0.id, RuleRow($0)) })
    }

    private func row(_ id: String, in store: LocalStore,
                     file: StaticString = #filePath, line: UInt = #line) throws -> RuleRow {
        try XCTUnwrap(try allRows(in: store)[id], "rule \(id) is missing", file: file, line: line)
    }

    /// 该桶活行的 `sortOrder` 升序序列（软删行不参与）。
    private func bucketOrder(_ spaceId: String, in rows: [String: RuleRow]) -> [Int] {
        rows.values
            .filter { $0.spaceId == spaceId && $0.deletedDate == nil }
            .map(\.sortOrder)
            .sorted()
    }

    private func drainMainQueue() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    /// `now` 的区间断言：戳落在调用前后两次取值之间。
    private func assertStampedNow(_ stamp: Date?, between start: Date, and end: Date,
                                  file: StaticString = #filePath, line: UInt = #line) {
        guard let stamp else {
            XCTFail("expected a `now` stamp, got nil", file: file, line: line)
            return
        }
        XCTAssertGreaterThanOrEqual(stamp, start, file: file, line: line)
        XCTAssertLessThanOrEqual(stamp, end, file: file, line: line)
    }

    private func assertFixedPoint(host: String, pathPrefix: String?,
                                  file: StaticString = #filePath, line: UInt = #line) {
        let once = LocalStore.normalizedRule(host: host, pathPrefix: pathPrefix)
        let twice = LocalStore.normalizedRule(host: once.host, pathPrefix: once.pathPrefix)
        XCTAssertEqual(twice.host, once.host, "host not a fixed point for \(host.debugDescription)",
                       file: file, line: line)
        XCTAssertEqual(twice.pathPrefix, once.pathPrefix,
                       "path not a fixed point for \(String(describing: pathPrefix).debugDescription)",
                       file: file, line: line)
    }

    // 断言是 autoclosure，先取值再断言。
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

    /// 仓库根下的一个源文件（`#filePath` 是 `Tests/PhiBrowserTests/<this>.swift`）。
    private static func repoFile(_ relativePath: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)
    }

    /// 确定性的随机源（SplitMix64），让 U-6 的 200 组构造可复现。
    private struct SeededGenerator: RandomNumberGenerator {
        private var state: UInt64

        init(seed: UInt64) {
            state = seed
        }

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }
}

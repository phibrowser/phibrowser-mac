// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Combine
import SwiftData
import XCTest
@testable import Phi

// URL 规则存储侧的 throwing 兄弟（M3-4a）。Task 4 放 CASE C-1 / C-2 / C-10 / C-11；
// Task 5 往同一个文件里追加 C-6 ~ C-9。
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
}

// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Combine
import SwiftData
import XCTest
@testable import Phi

// Throwing URL-rule storage APIs (M3-4a). Task 4 adds CASE C-1/C-2/C-10/C-11; Task 5
// adds C-6–C-9, C-12, U-6, U-15e, the flag-setting table, U-13/U-13c, and U-14-legacy.
//
// LocalStoreCompatibilityTests uses placeholder files and disposable schemas; it cannot
// open a real V11 store or run migrateV11toV12 (RT-8). Apart from production references
// in LocalStore.swift and AppController+UserDataBackup.swift, no other tests reference
// TabDataModelMigrationPlan. C-1/C-11 are the only real-store V11-to-V12 migration probes.
@MainActor
final class LocalStoreURLRuleThrowingTests: XCTestCase {
    private var tempDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in tempDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        tempDirectories.removeAll()
    }

    func testReleasedV10StoreRetainsIconsAndLayoutsAfterSyncMigration() throws {
        let directory = try makeTemporaryDirectory()
        try seedReleasedV10Store(at: directory)

        let container = try openWithProductionMigrationPlan(at: directory)
        let tabs = try container.mainContext.fetch(FetchDescriptor<TabDataModel>())
        let tab = try XCTUnwrap(tabs.first)
        XCTAssertEqual(tabs.count, 1)
        XCTAssertEqual(tab.guid, "dev-tab")
        XCTAssertEqual(tab.icon, "folder.work")
        XCTAssertEqual(tab.layout, "horizontal")
        XCTAssertEqual(tab.secondaryUrl, URL(string: "https://second.example"))
        XCTAssertNil(tab.syncId)
        let rules = try container.mainContext.fetch(FetchDescriptor<SpaceURLRule>())
        let rule = try XCTUnwrap(rules.first)
        XCTAssertEqual(rule.host, "dev.example")
        XCTAssertNotNil(UUID(uuidString: try XCTUnwrap(rule.syncId)))
    }

    private func seedReleasedV10Store(at directory: URL) throws {
        let configuration = ModelConfiguration(url: directory.appendingPathComponent("LocalStore.sqlite"))
        let container = try ModelContainer(
            for: TabDataModelSchemaV10.ProfileModel.self,
            TabDataModelSchemaV10.TabDataModel.self,
            TabDataModelSchemaV10.SpaceModel.self,
            TabDataModelSchemaV10.SpaceURLRule.self,
            TabDataModelSchemaV10.BrowserDataSettingsModel.self,
            configurations: configuration
        )
        let tab = TabDataModelSchemaV10.TabDataModel(
            title: "Dev tab", guid: "dev-tab", index: 0,
            url: try XCTUnwrap(URL(string: "https://dev.example")),
            favicon: nil, createdDate: Date(), updatedDate: Date()
        )
        tab.icon = "folder.work"
        tab.layout = "horizontal"
        tab.secondaryUrl = URL(string: "https://second.example")
        container.mainContext.insert(tab)
        container.mainContext.insert(TabDataModelSchemaV10.SpaceURLRule(
            id: "dev-rule", spaceId: "dev-space", host: "dev.example", sortOrder: 0
        ))
        try container.mainContext.save()
    }

    // MARK: - CASE C-1: Real-store V11-to-V12 migration

    // Detects an omitted model among the five, a mistyped column that prevents lightweight
    // migration, and uppercase UUIDs minted by backfill.
    func testV11StoreMigratesToV12PreservingEveryRuleAndBackfillingSyncId() throws {
        let directory = try makeTemporaryDirectory()
        let seeded = try seedV11Store(at: directory, rules: Self.fourRules)

        let container = try openWithProductionMigrationPlan(at: directory)
        let context = container.mainContext

        let profiles = try context.fetch(FetchDescriptor<ProfileModel>())
        let spaces = try context.fetch(FetchDescriptor<SpaceModel>())
        let tabs = try context.fetch(FetchDescriptor<TabDataModel>())
        let rules = try context.fetch(FetchDescriptor<SpaceURLRule>(
            sortBy: [SortDescriptor(\.spaceId), SortDescriptor(\.sortOrder)]
        ))

        // Preserve the row count for every model type.
        XCTAssertEqual(profiles.count, 2)
        XCTAssertEqual(spaces.count, 3)
        XCTAssertEqual(tabs.count, seeded.tabCount)
        XCTAssertEqual(rules.count, 4)
        XCTAssertEqual(Set(profiles.map(\.profileId)), Set(seeded.profileIds))
        XCTAssertEqual(Set(spaces.map(\.spaceId)), Set(seeded.spaceIds))
        XCTAssertEqual(Set(tabs.map(\.guid)), Set(seeded.tabGuids))

        // Preserve all seven V11 rule fields exactly, including the nil pathPrefix.
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

        // All four syncIds are nonnil, distinct, and lowercase (R-M3-4a-23 backfill).
        let syncIds = try rules.map { try XCTUnwrap($0.syncId, "rule \($0.id) has no syncId after migration") }
        XCTAssertEqual(Set(syncIds).count, 4)
        for syncId in syncIds {
            XCTAssertEqual(syncId, syncId.lowercased())
            XCTAssertNotNil(UUID(uuidString: syncId))
        }

        // The other five columns retain their defaults.
        for row in rules {
            XCTAssertNil(row.contentUpdatedDate)
            XCTAssertNil(row.targetUpdatedDate)
            XCTAssertNil(row.deletedDate)
            XCTAssertFalse(row.pendingLocalEdit)
            XCTAssertNil(row.mergePartnerSyncId)
        }

        // The two ProfileModel columns are unused in M3-4a and are not backfilled.
        for profile in profiles {
            XCTAssertNil(profile.syncId)
            XCTAssertNil(profile.createdDate)
        }
    }

    // MARK: - CASE C-2: Migration-plan structure assertions

    // If migrateV11toV12 is omitted from stages, schemas and the typealias still name V12,
    // so SwiftData can infer a lightweight migration while skipping didMigrate's syncId
    // backfill entirely. This is the only detector of that omission.
    func testMigrationPlanEndsAtV12WithOneStagePerUpgrade() throws {
        let schemas = TabDataModelMigrationPlan.schemas
        let stages = TabDataModelMigrationPlan.stages

        XCTAssertEqual(schemas.count, 12)
        XCTAssertEqual(stages.count, schemas.count - 1)
        let last = try XCTUnwrap(schemas.last)
        XCTAssertEqual(ObjectIdentifier(last), ObjectIdentifier(TabDataModelSchemaV12.self))
        XCTAssertEqual(TabDataModelSchemaV12.versionIdentifier, Schema.Version(12, 0, 0))
        XCTAssertEqual(TabDataModelSchemaV12.models.count, 5)
    }

    // MARK: - CASE C-10: Default deletedDate read filtering (R-M3-4a-51)

    // Including soft-deleted rows in default reads includes them in dense sortOrder
    // normalization. The deleting device retains those indexes, while the follower hard-deletes
    // inbound tombstones; indexes then differ by the number of preceding deleted rows,
    // changing cross-Space tie winners. An unfiltered publisher also keeps deleted rules
    // visible in the editor and active in Chromium routing.
    func testDefaultReadPathsHideSoftDeletedRules() throws {
        let directory = try makeTemporaryDirectory()
        let store = LocalStore(
            account: Account(userID: UUID().uuidString),
            storeDirectoryURL: directory,
            presentsCompatibilityAlerts: false
        )
        let context = try XCTUnwrap(store.getMainContext())

        // Subscribe and receive the initial empty-store value before inserting and saving rows.
        var emissions: [[SpaceRoutingRule]] = []
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

        // ① Read all rules.
        let all = store.getAllURLRules()
        XCTAssertEqual(all.map(\.id), ["a-0", "a-2", "b-0"])
        XCTAssertFalse(all.contains { $0.id == softDeletedId })

        // ② Read by Space without renumbering: sortOrder remains [0, 2].
        let spaceA = store.getURLRules(forSpaceId: "space-a")
        XCTAssertEqual(spaceA.map(\.id), ["a-0", "a-2"])
        XCTAssertEqual(spaceA.map(\.sortOrder), [0, 2])

        // ③ The publisher value emitted after NSManagedObjectContextDidSave.
        wait(for: [postSave], timeout: 5)
        XCTAssertEqual(emissions.count, 2)
        let published = try XCTUnwrap(emissions.last)
        XCTAssertEqual(published.map(\.id), all.map(\.id))
        XCTAssertEqual(published.map(\.spaceId), all.map(\.spaceId))
        XCTAssertEqual(published.map(\.sortOrder), all.map(\.sortOrder))
        XCTAssertFalse(published.contains { $0.id == softDeletedId })
    }

    // MARK: - CASE C-11: Idempotent backfill of n distinct lowercase UUIDs for n rows (R-M3-4a-23)

    // Without lowercased(), local identities differ from other devices' lowercase UUIDs and
    // per-row syncId addressing can split one rule into two. Without the syncId == nil guard,
    // a repeat backfill remints published identities, orphaning account entities and leaving
    // two rules with the old one permanently unclaimed.
    func testSyncIdBackfillMintsDistinctLowercaseUUIDsAndIsIdempotent() throws {
        let directory = try makeTemporaryDirectory()
        _ = try seedV11Store(at: directory, rules: Self.sixRules)

        // ① First open: run production migrateV11toV12 and record the six syncIds.
        let firstOpen = try readSyncIdsAfterProductionOpen(at: directory)
        XCTAssertEqual(firstOpen.count, 6)
        XCTAssertEqual(Set(firstOpen.values).count, 6)
        for syncId in firstOpen.values {
            XCTAssertEqual(syncId, syncId.lowercased())
            XCTAssertNotNil(UUID(uuidString: syncId))
        }

        // ② Reopen the V12 store, which skips didMigrate; manually repeat equivalent backfill
        // reads and writes in this context to prove the closure itself is idempotent.
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

    private struct SeededV11Store {
        let profileIds: [String]
        let spaceIds: [String]
        let tabGuids: [String]
        var tabCount: Int { tabGuids.count }
    }

    // Four rows in two Space buckets with dense sortOrder; one has nil pathPrefix.
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

    /// Create a real ModelContainer with explicit V11 model types, following
    /// PinnedTabScopeTests.seedV8Store(at:). Write two Profiles, three Spaces, the rules,
    /// and three tabs; save and release the container.
    @discardableResult
    private func seedV11Store(at directory: URL, rules: [SeedRule]) throws -> SeededV11Store {
        let configuration = ModelConfiguration(
            url: directory.appendingPathComponent("LocalStore.sqlite")
        )
        let container = try ModelContainer(
            for: TabDataModelSchemaV11.ProfileModel.self,
            TabDataModelSchemaV11.TabDataModel.self,
            TabDataModelSchemaV11.SpaceModel.self,
            TabDataModelSchemaV11.SpaceURLRule.self,
            TabDataModelSchemaV11.BrowserDataSettingsModel.self,
            configurations: configuration
        )
        let context = container.mainContext

        let profileIds = ["Default", "Work"]
        for profileId in profileIds {
            context.insert(TabDataModelSchemaV11.ProfileModel(profileId: profileId))
        }

        let spaceIds = ["space-a", "space-b", "space-c"]
        for (index, spaceId) in spaceIds.enumerated() {
            context.insert(TabDataModelSchemaV11.SpaceModel(
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
            let tab = TabDataModelSchemaV11.TabDataModel(
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
            context.insert(TabDataModelSchemaV11.SpaceURLRule(
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
        return SeededV11Store(profileIds: profileIds, spaceIds: spaceIds, tabGuids: tabGuids)
    }

    /// Reopen the store with production TabDataModelMigrationPlan and V12 aliases, using
    /// the exact model list from LocalStore.swift's ModelContainer(for:).
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

    /// Open once and read each rule's syncId by id; release the container before returning.
    private func readSyncIdsAfterProductionOpen(at directory: URL) throws -> [String: String] {
        let container = try openWithProductionMigrationPlan(at: directory)
        let rules = try container.mainContext.fetch(FetchDescriptor<SpaceURLRule>())
        var byId: [String: String] = [:]
        for rule in rules {
            byId[rule.id] = try XCTUnwrap(rule.syncId, "rule \(rule.id) has no syncId after migration")
        }
        return byId
    }

    // MARK: - Task 5: Write APIs, per-row primitives, normalization, and cascade origin

    private static let spaceOne = "space-1"
    private static let spaceTwo = "space-2"
    private static let spaceThree = "space-3"
    // nonisolated: landing's default arguments are evaluated outside actor isolation.
    // Referencing a main-actor static there warns; this immutable Sendable constant is safe to isolate independently.
    private nonisolated static let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private static let t1 = Date(timeIntervalSince1970: 1_700_000_500)

    // MARK: CASE C-6: The sole public API throws, with no fire-and-forget alternative (R-M3-4a-49)

    // The old replace paths used performBackgroundWrite, returned silently for nil writeActor,
    // and swallowed body errors in catch { AppLogError... }. Callers could not distinguish
    // failure from persistence; retaining a nonthrowing API would let them return to that path.
    func testApplyURLRuleEditsThrowsStoreUnavailableWhenTheStoreNeverOpened() async throws {
        // (a) Occupy the store directory path with a regular file. LocalStore.init's try?
        // createDirectory fails, then prepareStore's createDirectory throws: failed state, nil writeActor.
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
        // (b) A normal store containing A (R1) and B (R2).
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

        // Structural assertion: LocalStore has no nonthrowing applyURLRuleEdits(upserts:deletedIds:)
        // and neither old replace API remains.
        let source = try String(contentsOf: Self.repoFile("Sources/LocalStorage/LocalStore+SpaceURLRule.swift"),
                                encoding: .utf8)
        XCTAssertFalse(source.contains("func applyURLRuleEdits("))
        XCTAssertFalse(source.contains("func replaceURLRules("))
        XCTAssertFalse(source.contains("func replaceAllURLRules("))
        XCTAssertTrue(source.contains("func applyURLRuleEditsThrowing("))
    }

    // MARK: CASE C-7: Change only the named rows and fields

    // Delete-then-insert used to remint every id in the bucket on save. Marking soft-deleted
    // rows would let them yield to inbound tombstones; failing to renumber r2 leaves indexes
    // 0/2. Part (b) prevents the insert branch from replacing nil cells with defaults and
    // letting empty host or spaceId values enter routing, snapshots, and the account.
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

        // r2 remains unchanged except sortOrder becomes 1 to close the soft-deletion gap (ruling 4).
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

        // Nonnil content, nil spaceId.
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
        // Conversely: nonnil spaceId, nil content.
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

    // MARK: CASE C-8: An id crossing buckets is a valid target change (R-M3-4a-80)

    // A per-target-Space index mistakes this move for a caller error and throws rowAlreadyMapped.
    // Inserting on lookup failure instead creates two rules sharing one syncId. Normalizing
    // only the target bucket leaves indexes 0/2 in S1.
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

    // MARK: CASE C-8b: Rules use rowAlreadyMapped only for syncId collisions (R-M3-4a-80)

    // Checking only whether a row already has another syncId misses a syncId owned by a
    // different id, allowing duplicate account identities. Per-row commits without
    // performThrowing rollback leave partial application. Put the valid upsert first so rollback has real work to undo.
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

    // MARK: CASE C-9: Per-row syncId guards and soft-deleted addressing (R-M3-4a-56 / R-M3-4a-42(a))

    // Using default reads filtered by deletedDate == nil inserts a duplicate syncId for
    // a soft-deleted row. Soft-deleting inbound tombstones never removes follower rows;
    // stamping application with now fabricates freshness that can beat real remote edits.
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

        // ① Address the soft-deleted row without duplication; clear deletedDate and
        // mergePartnerSyncId in the same write, preserve both input timestamps, and leave pendingLocalEdit unchanged.
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

        // ② Hard deletion removes the row from the store.
        try await store.hardDeleteURLRuleThrowing(syncId: "R1")
        let afterDelete = try allRows(in: store)
        XCTAssertEqual(afterDelete.count, 1)
        XCTAssertNil(afterDelete["A"])
        XCTAssertEqual(afterDelete["B"], afterUpsert["B"])
        // A missing identity is a silent no-op for an inbound tombstone with no local row.
        try await store.hardDeleteURLRuleThrowing(syncId: "R1")
        XCTAssertEqual(try allRows(in: store).count, 1)

        // ③ Change B.syncId to R3, then apply R2. The primitive addresses only syncId, with
        // no local id parameter: R2 is absent from the full table, so create a row without
        // changing B (see the Task 5 ledger note).
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

        // ④ An unseen identity creates a row rather than throwing rowNotFound (R-M3-4a-42(a)).
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

    // MARK: CASE C-12: A draft with nil syncId matching a soft-deleted row creates a new row (R-M3-4a-104 / ruling 8)

    // An in-place upsert ignoring deletedDate writes the edit into an invisible row, then
    // tombstone acceptance hard-deletes it: a successful save loses the rule. Resurrecting
    // the row is also wrong; only 3b does that. Reusing draft.id violates Attribute.unique.
    // Variant ② keeps the APIs distinct: the per-row primitive in C-9 ① must address the
    // soft-deleted row and clear deletedDate.
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
        XCTAssertNil(fresh.contentUpdatedDate, "a new row does not mint a content stamp (ruling 5)")
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

    // MARK: CASE U-6: Normalization is a fixed point (R-M3-4a-21 / §8.1)

    // Stripping trailing slashes before decoding makes f("/%2F") == "//", silently widening
    // semantics. Stripping dots before trimming maps host "a. ." to "a.". Without a fixed
    // point, every normalization triggers mustRepublish and another commit, preventing convergence.
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

        // Two hundred randomly generated inputs with a deterministic seed.
        var generator = SeededGenerator(seed: 0x5EED_5EED)
        let atoms = ["a", "Z", "7", ".", " ", "\n", "/", "%", "2F", "é", "\u{4e2d}", "-"]
        for _ in 0..<200 {
            let host = (0..<Int.random(in: 0...8, using: &generator))
                .map { _ in atoms[Int.random(in: 0..<atoms.count, using: &generator)] }
                .joined()
            let path = (0..<Int.random(in: 0...8, using: &generator))
                .map { _ in atoms[Int.random(in: 0..<atoms.count, using: &generator)] }
                .joined()
            assertFixedPoint(host: host, pathPrefix: path)
        }

        // Concrete expected values.
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
        // The flat convenience initializer also passes through ContentUnit.
        let flat = LocalStore.URLRuleDraft(host: rawHost, pathPrefix: rawPath, spaceId: Self.spaceOne)
        XCTAssertEqual(flat.content?.host, unit.host)
        XCTAssertEqual(flat.content?.pathPrefix, unit.pathPrefix)
        XCTAssertEqual(flat.host, unit.host)
        XCTAssertEqual(flat.pathPrefix, unit.pathPrefix)
    }

    // MARK: CASE U-15e: Retargeting moves buckets, store side (R-M3-4a-80)

    // Covers C-8 plus implementations that split retargeting into delete and insert:
    // changing syncId severs the account rule's history, including both timestamps.
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

    // MARK: CASE 5 flag-setting table: One case per §4.3 row (R-M3-4a-11 / 48 / 65 / 69 / 72)

    // Stamping both groups on any row change advances targetUpdatedDate for a rename (⑤).
    // Treating nil cells as explicit nil/default writes clears spaceId in ① and host in ②.
    // Flagging every upsert makes no-ops ④/⑥ leave quiescence; not flagging drag operations
    // lets convergence overwrite the user's ordering intent with machine writes.
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
        // Simulate a remote retarget applied while the sheet is open.
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

    // MARK: CASE U-13: User deletes a Space, store side (R-M3-4a-24 / 41 / 85)

    // Hard-deleting rules loses deletedDate. Deleting SpaceModel in the same batch while
    // retaining its mapping yields zero URL-rule tombstones and account orphans no device
    // can delete. Flagging every row in the shared body makes these three soft-deleted
    // rows yield to inbound tombstones.
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

    // MARK: CASE U-13c: Purge is not deletion intent, store side (R-M3-4a-85)

    // Treating purge as userIntent, or unconditionally soft-deleting in the shared body,
    // sets deletedDate and triggers §5.7 origin (b), bypassing both ownership gates. That
    // can delete a rule parked under another Space while it remains valid remotely.
    // A default origin argument would hide a missing argument at either entry point.
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

    // MARK: CASE U-14-legacy: Historical non-UUID id, store side (R-M3-4a-13 / ruling 3)

    // Following §4.3 rule 3 literally and inserting on an id miss creates a second R1 row,
    // so the next snapshot has two rows claiming one account identity. Throwing
    // rowAlreadyMapped for the syncId fallback instead makes editor saves fail the entire batch.
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

    // MARK: - Task 8: Batch application, AccountPhiURLRuleAccess, committed reads, and urlRuleChangesPublisher

    // MARK: CASE U-10: Owner changes preserve identity and normalize both buckets (R-M3-4a-3 / R-M3-4a-51)

    // Delete-plus-insert rehoming changes id and syncId, making the next diff tombstone
    // the old identity. Normalizing only one bucket leaves a source index gap; sortOrder
    // is the third Specificity component.
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

    // MARK: CASE U-10b: A pure reorder must not become a rehome (real-store half)

    // Treating every move as a rehome needlessly normalizes an untouched bucket.
    // That write triggers §6.5's publisher and an extra push round, violating steady-state pushed == 0.
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

    // MARK: CASE U-10c: Retarget to Incognito using the bare prefix constant

    // Resolving the reserved constant to a live incognito runtime id makes the rule's
    // target invalid after restart, when isRoutableRuleTarget returns false.
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

    // MARK: CASE U-10d: Incognito to Space normalizes both buckets once

    // Skipping the reserved-constant bucket as unreal leaves an index gap in Incognito.
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

    // MARK: CASE U-10e ②: One write per identity per page, real-store half

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

    // MARK: CASE U-10f: Create missing rows from the payload (R-M3-4a-42(a) / R-M3-4a-56)

    // Throwing rowNotFound retries the batch forever. Checking allURLRules(), which filters
    // soft deletions, can insert a second row with the same syncId; uniqueness applies
    // only to id, so the database cannot prevent this.
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

    // The restored row was excluded from siblings(inSpaceId:)'s live rows. Its payload
    // index can collide with a live row (R-M3-4a-3 / RR-B9), so restoration counts as
    // entering the bucket. Deliberately restore to an occupied index.
    func testUpdateHittingASoftDeletedRowRevivesItInPlaceWithoutASecondRow() async throws {
        let store = try makeStore()
        try await seed(Self.twoBucketSeeds + [
            RuleSeed(id: "s1-9", spaceId: Self.spaceOne, host: "s1-9.example", sortOrder: 9, syncId: "R-s1-9",
                     deletedDate: Self.t1, mergePartnerSyncId: "R-s1-0"),
        ], in: store)
        let before = try allRows(in: store)
        XCTAssertEqual(bucketOrder(Self.spaceOne, in: before), [0, 1, 2], "index 1 is taken before the revive")

        let values = landing("R-s1-9", spaceId: Self.spaceOne, host: "revived.example", sortOrder: 1)
        try await store.applyURLRuleSyncBatchThrowing([.update(values)])

        let after = try allRows(in: store)
        XCTAssertEqual(after.count, 6, "no second row for R-s1-9")
        XCTAssertEqual(after.values.filter { $0.syncId == "R-s1-9" }.count, 1)
        let revived = try XCTUnwrap(after["s1-9"])
        XCTAssertNil(revived.deletedDate)
        XCTAssertNil(revived.mergePartnerSyncId)
        XCTAssertEqual(revived.host, "revived.example")
        XCTAssertFalse(revived.pendingLocalEdit)
        // A complete permutation with no duplicates: pre-apply (sortOrder, id) puts s1-1(1)
        // before s1-9(1), displacing s1-2 to index 3.
        XCTAssertEqual(bucketOrder(Self.spaceOne, in: after), [0, 1, 2, 3])
        XCTAssertEqual(["s1-0", "s1-1", "s1-9", "s1-2"].compactMap { after[$0]?.sortOrder }, [0, 1, 2, 3])
        XCTAssertEqual(after["s2-0"], before["s2-0"], "the other bucket is not written")
        XCTAssertEqual(after["s2-1"], before["s2-1"])
    }

    // MARK: CASE U-16: Final dense sortOrder includes unidentified and parked rows (R-M3-4a-3 / §8.3)

    // Normalizing only this round's sync participants leaves excluded siblings' stale
    // indexes colliding with newly written indexes.
    func testTrailingDensificationRenumbersEveryLiveRowInTheBucket() async throws {
        let store = try makeStore()
        try await seed([
            RuleSeed(id: "p0", spaceId: Self.spaceOne, host: "p0.example", sortOrder: 0, syncId: "R-p0"),
            RuleSeed(id: "p1", spaceId: Self.spaceOne, host: "p1.example", sortOrder: 3, syncId: "R-p1"),
            // Never published to the account.
            RuleSeed(id: "u2", spaceId: Self.spaceOne, host: "u2.example", sortOrder: 3, syncId: nil),
            // The cursor is parked: the row exists, but sync does not touch it this round.
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

    // MARK: CASE U-26: Apply both remote timestamps without minting now (R-M3-4a-20 / R-M3-4a-48)

    // Stamping application with now makes the follower newer than the account. If cursor
    // corruption triggers full-type replay, the fabricated freshness wins against the
    // author's real edit. The second section catches writing only one of the two stamps.
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

        // Second section: content-only update, content stamp 900 and target stamp still 700.
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

    // MARK: CASE U-24: Post-apply refresh reads committed rows (R-M3-4a-34 / R-M3-4a-49)

    // performBackgroundWrite returns before commit, so an immediate refetch sees stale
    // values. Read first to register rows in the main context, as SpaceManager.cachedURLRules
    // does, then assert the new values are visible immediately after await returns.
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

    // MARK: CASE U-24b: Editor writes also refresh from committed rows

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

    // MARK: CASE U-24c: All three agent writes share the same commit guarantee (add, edit host, delete)

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

    // MARK: CASE U-24d: Space collection changes also refresh, real-store half (R-M3-4a-50 row 6)

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

    // MARK: AccountPhiURLRuleAccess: Both reads, cache readers, liveOwners, and post-apply rereads

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

    // MARK: CASE U-8p: Store signal coalesces, omits initial emission, and includes soft deletion (§6.5 / R-M3-4a-51)

    // Without coalescing, 30 applied rows queue 30 push rounds; seeding the current value
    // adds a round on every subscription. A snapshot built from filtered rows suppresses
    // soft deletion, the sole carrier of local delete intent. Delete the last bucket row
    // so only deletedDate changes.
    func testURLRuleChangesPublisherCollapsesBurstsDoesNotSeedAndEmitsForSoftDeletes() async throws {
        let store = try makeStore()
        var received = 0
        let cancellable = store.urlRuleChangesPublisher(debounceWindow: Self.shortDebounceWindow)
            .sink { _ in received += 1 }
        defer { cancellable.cancel() }

        waitPastDebounceWindow(Self.shortDebounceWindow)
        let afterQuietPeriod = received
        XCTAssertEqual(afterQuietPeriod, 0, "Subscription does not emit the current value")

        for index in 0..<30 {
            try await store.applyURLRuleEditsThrowing(
                upserts: [LocalStore.URLRuleDraft(id: "burst-\(index)", host: "burst-\(index).example",
                                                  spaceId: Self.spaceOne)],
                deletedIds: []
            )
        }
        waitPastDebounceWindow(Self.shortDebounceWindow)
        let afterBurst = received
        XCTAssertEqual(afterBurst, 1, "Thirty writes collapse into one debounced emission")

        try await store.applyURLRuleEditsThrowing(upserts: [], deletedIds: ["burst-29"])
        waitPastDebounceWindow(Self.shortDebounceWindow)
        let afterSoftDelete = received
        XCTAssertEqual(afterSoftDelete, 2, "a soft delete is a change the diff must see")
    }

    // MARK: - Task 8 fixtures

    private static let shortDebounceWindow: TimeInterval = 0.2

    /// Application payload; all three timestamps default to t0 unless a case supplies explicit values.
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

    // MARK: - 8b-1: CASE M-32 (a re-key syncId collision rolls back the whole batch)

    // The bookmark claim guard (nil syncId or equal new value) rejects every rule re-key,
    // which necessarily replaces a nonnil identity. Omitting collision checks lets two
    // rows share an account identity (only id is unique), leaving an identity unclaimed
    // and tombstoned by the next diff. Part (a) requires idempotent acceptance of equality;
    // otherwise CASE M-13 replay throws.
    private static let rekeySeeds: [RuleSeed] = [
        RuleSeed(id: "i1", spaceId: spaceOne, host: "a.example", sortOrder: 0, syncId: "local-a",
                 contentUpdatedDate: t0, targetUpdatedDate: t0),
        RuleSeed(id: "i2", spaceId: spaceOne, host: "b.example", sortOrder: 1, syncId: "remote-b",
                 contentUpdatedDate: t0, targetUpdatedDate: t0),
        RuleSeed(id: "i3", spaceId: spaceTwo, host: "c.example", sortOrder: 0, syncId: "R3",
                 contentUpdatedDate: t0, targetUpdatedDate: t0),
    ]

    /// Update another identity in the same batch so rollback has actual work to undo.
    private var unrelatedUpdate: URLRuleSyncOp {
        .update(landing("R3", spaceId: Self.spaceTwo, host: "changed.example", sortOrder: 0,
                        contentUpdatedDate: Self.t1))
    }

    func testRekeyOntoAnotherRowsSyncIdThrowsRowAlreadyMappedAndRollsBackTheBatch() async throws {
        let store = try makeStore()
        try await seed(Self.rekeySeeds, in: store)
        let before = try allRows(in: store)

        await assertThrows(.rowAlreadyMapped) {
            try await store.applyURLRuleSyncBatchThrowing(
                [.rekey(localId: "i1", to: "remote-b", values: nil), self.unrelatedUpdate])
        }

        let after = try allRows(in: store)
        XCTAssertEqual(after, before, "The store remains unchanged")
        XCTAssertEqual(after["i1"]?.syncId, "local-a")
        XCTAssertEqual(after["i2"]?.syncId, "remote-b")
        XCTAssertEqual(after["i3"]?.host, "c.example", "The update is also rolled back")
    }

    /// (a) Idempotence: to equals the current value, so no throw and no row write.
    func testRekeyOntoTheRowsOwnSyncIdIsAnIdempotentNoOp() async throws {
        let store = try makeStore()
        try await seed(Self.rekeySeeds, in: store)
        let before = try allRows(in: store)

        try await store.applyURLRuleSyncBatchThrowing([.rekey(localId: "i1", to: "local-a", values: nil)])

        XCTAssertEqual(try allRows(in: store), before, "No row writes")
    }

    /// (b) Missing localId throws rowNotFound and rolls back the entire batch.
    func testRekeyOfAnUnknownLocalIdThrowsRowNotFoundAndRollsBackTheBatch() async throws {
        let store = try makeStore()
        try await seed(Self.rekeySeeds, in: store)
        let before = try allRows(in: store)

        await assertThrows(.rowNotFound) {
            try await store.applyURLRuleSyncBatchThrowing(
                [.rekey(localId: "nope", to: "acc-1", values: nil), self.unrelatedUpdate])
        }

        XCTAssertEqual(try allRows(in: store), before)
    }

    /// (c) A soft-deleted row cannot be claimed: rowNotFound and full rollback.
    func testRekeyOfASoftDeletedRowThrowsRowNotFoundAndRollsBackTheBatch() async throws {
        let store = try makeStore()
        var seeds = Self.rekeySeeds
        seeds[0].deletedDate = Self.t1
        try await seed(seeds, in: store)
        let before = try allRows(in: store)

        await assertThrows(.rowNotFound) {
            try await store.applyURLRuleSyncBatchThrowing(
                [.rekey(localId: "i1", to: "acc-1", values: nil), self.unrelatedUpdate])
        }

        let after = try allRows(in: store)
        XCTAssertEqual(after, before)
        XCTAssertEqual(after["i1"]?.syncId, "local-a")
        XCTAssertNotNil(after["i1"]?.deletedDate)
    }

    /// Positive case: re-key writes only syncId, preserving stamps, flags, and
    /// mergePartnerSyncId. With values, the merged fields apply under the new identity
    /// in the same write block, still leaving pendingLocalEdit untouched.
    func testRekeyWritesOnlyTheSyncIdAndLandsTheMergedValuesUnderTheNewIdentity() async throws {
        let store = try makeStore()
        var seeds = Self.rekeySeeds
        seeds[0].pendingLocalEdit = true
        seeds[0].mergePartnerSyncId = "w"
        try await seed(seeds, in: store)

        try await store.applyURLRuleSyncBatchThrowing([.rekey(localId: "i1", to: "acc-1", values: nil)])
        let rekeyed = try row("i1", in: store)
        XCTAssertEqual(rekeyed.syncId, "acc-1")
        XCTAssertEqual(rekeyed.host, "a.example")
        XCTAssertEqual(rekeyed.contentUpdatedDate, Self.t0, "The timestamp is unchanged")
        XCTAssertTrue(rekeyed.pendingLocalEdit, "The flag is not cleared")
        XCTAssertEqual(rekeyed.mergePartnerSyncId, "w", "This column remains unchanged")

        try await store.applyURLRuleSyncBatchThrowing([
            .rekey(localId: "i1", to: "acc-2",
                   values: landing("acc-2", spaceId: Self.spaceOne, host: "merged.example",
                                   sortOrder: 0, contentUpdatedDate: Self.t1)),
        ])
        let landed = try row("i1", in: store)
        XCTAssertEqual(landed.syncId, "acc-2")
        XCTAssertEqual(landed.host, "merged.example", "Merged values address the same row through its new identity")
        XCTAssertEqual(landed.contentUpdatedDate, Self.t1)
        XCTAssertTrue(landed.pendingLocalEdit)
        XCTAssertEqual(landed.mergePartnerSyncId, "w")
        XCTAssertEqual(try allRows(in: store).count, 3, "No duplicate row is inserted")
    }

    /// Wait the debounce window plus main-queue delivery allowance, as in LocalStoreBookmarkThrowingTests.
    private func waitPastDebounceWindow(_ window: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(window + 0.6))
    }

    // MARK: - Task 5 fixtures

    /// The thirteen row columns; construct SpaceURLRule inside the write block so Model instances never cross contexts.
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

    /// Value snapshot of all thirteen columns, fetched from the main context including soft-deleted rows.
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

    // Three S1 rows (0/1/2) and two S2 rows (0/1), all with syncId and a fixed contentUpdatedDate.
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

    /// U-13/U-13c fixture: one S1 SpaceModel, two S1 tabs and an S2 control tab, three
    /// S1 rules with pendingLocalEdit = false, and one S2 control rule.
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

    /// Ascending sortOrder values for live rows in the bucket, excluding soft-deleted rows.
    private func bucketOrder(_ spaceId: String, in rows: [String: RuleRow]) -> [Int] {
        rows.values
            .filter { $0.spaceId == spaceId && $0.deletedDate == nil }
            .map(\.sortOrder)
            .sorted()
    }

    private func drainMainQueue() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    /// Assert now falls between timestamps taken immediately before and after the call.
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

    // Assertions use autoclosures; read values before asserting.
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

    /// A source file relative to the repository root; #filePath is Tests/PhiBrowserTests/<this>.swift.
    private static func repoFile(_ relativePath: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)
    }

    /// Deterministic SplitMix64 random source keeps U-6's 200 generated inputs reproducible.
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

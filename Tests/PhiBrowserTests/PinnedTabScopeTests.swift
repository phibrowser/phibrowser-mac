// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Combine
import SwiftData
import XCTest
@testable import Phi

@MainActor
final class PinnedTabScopeTests: XCTestCase {
    private var tempDirectories: [URL] = []
    private var cancellables: Set<AnyCancellable> = []

    override func tearDownWithError() throws {
        // 这个类驱动真的作用域迁移，而迁移的成功路径写 `UserDefaults.standard`——在 hosted
        // 测试里那就是 Phi 自己的偏好域。
        clearPinnedTabScopeMirrorDefaults()
        cancellables.removeAll()
        for directory in tempDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        tempDirectories.removeAll()
    }

    func testV8MigrationDefaultsToProfileAndBackfillsPinnedLineage() throws {
        let directory = try makeTemporaryDirectory()
        try seedV8Store(at: directory)

        let store = LocalStore(
            account: Account(userID: UUID().uuidString),
            storeDirectoryURL: directory,
            presentsCompatibilityAlerts: false
        )

        XCTAssertEqual(store.pinnedTabScope(), .profile)
        let pinned = store.getAllPinnedTabs(for: "Default", spaceId: "space-a")
        XCTAssertEqual(pinned.map(\.guid), ["v8-pin"])
        XCTAssertEqual(pinned.first?.pinLineageId, "v8-pin")
    }

    func testDefaultScopeIsProfileAndQueriesRemainProfileIsolated() throws {
        let store = try makeStore()
        let fixture = try seedProfilesAndSpaces(in: store)
        try insertPinnedTab(
            in: store,
            guid: "default-pin",
            lineageId: "default-lineage",
            profile: fixture.defaultProfile,
            title: "Default",
            url: "https://default.example"
        )
        try insertPinnedTab(
            in: store,
            guid: "work-pin",
            lineageId: "work-lineage",
            profile: fixture.workProfile,
            title: "Work",
            url: "https://work.example"
        )

        XCTAssertEqual(store.pinnedTabScope(), .profile)
        XCTAssertEqual(
            store.getAllPinnedTabs(for: "Default", spaceId: "space-a").map(\.guid),
            ["default-pin"]
        )
        XCTAssertEqual(
            store.getAllPinnedTabs(for: "Work", spaceId: "space-c").map(\.guid),
            ["work-pin"]
        )
    }

    func testProfileToSpaceCopiesRowsWithIndependentGuidsAndRemappedSplitPartners() async throws {
        let store = try makeStore()
        let fixture = try seedProfilesAndSpaces(in: store)
        try seedPinnedSplit(in: store, profile: fixture.defaultProfile)
        try insertPinnedTab(
            in: store,
            guid: "work-pin",
            lineageId: "work-lineage",
            profile: fixture.workProfile,
            title: "Work",
            url: "https://work.example"
        )

        try await store.changePinnedTabScope(
            to: .space,
            preferredProfileId: "Default",
            preferredSpaceId: "space-a"
        )
        try drainMainQueue()

        let spaceA = store.getAllPinnedTabs(for: "Default", spaceId: "space-a")
        let spaceB = store.getAllPinnedTabs(for: "Default", spaceId: "space-b")
        let spaceC = store.getAllPinnedTabs(for: "Work", spaceId: "space-c")
        XCTAssertEqual(store.pinnedTabScope(), .space)
        XCTAssertEqual(spaceA.map(\.pinLineageId), ["left-lineage", "right-lineage"])
        XCTAssertEqual(spaceB.map(\.pinLineageId), ["left-lineage", "right-lineage"])
        XCTAssertEqual(spaceC.map(\.pinLineageId), ["work-lineage"])
        XCTAssertNotEqual(spaceA.map(\.guid), spaceB.map(\.guid))
        assertSplitPair(spaceA)
        assertSplitPair(spaceB)

        store.updateTabURL(
            try XCTUnwrap(spaceA.first).guid,
            url: try XCTUnwrap(URL(string: "https://changed.example"))
        )
        await flushWrites(store)
        try drainMainQueue()

        XCTAssertEqual(
            store.getAllPinnedTabs(for: "Default", spaceId: "space-a").first?.url.absoluteString,
            "https://changed.example"
        )
        XCTAssertEqual(
            store.getAllPinnedTabs(for: "Default", spaceId: "space-b").first?.url.absoluteString,
            "https://left.example"
        )
    }

    /// 迁移之后，**同一个后台写上下文上的第二次写必须还能提交**，而且一条必填列为空的
    /// `TabDataModel` 都不存在。
    ///
    /// 防的是什么：`insertPinnedTabs` 里 `applyPinnedTabOwner`（它写 `model.profile`）一度
    /// 排在 `context.insert(model)` **之前**。`ProfileModel.tabs` 是那一笔的 inverse，于是
    /// 每建一条 pin，SwiftData 就为那条 inverse 现造一个六个必填列全空的 `TabDataModel`
    /// 替身登记进上下文。**迁移那一次 save 照样可能过**（Mac B 2026-09-14 的现场就是这样），
    /// 坏在此后：替身留在上下文里，此后每一次 save 都把它们物化一遍并整批校验失败
    /// （NSCocoaErrorDomain 1560），直到有人 rollback。所以**第二次写**才是这条用例的载荷。
    ///
    /// 3 条 lineage × 2 个 Space（`Default` 名下的 `space-a` / `space-b`）= 6 条新行，与现场
    /// 那六个替身同一个规模。
    ///
    /// **这是一条 characterisation 用例，不是探针。** 它钉的是「迁移之后这个上下文仍然可
    /// 写」这条不变量，但**不能证明**它在修复之前会红：现场那六个替身是在迁移的 save 成功
    /// 之后大约 100 秒才开始让每一次 save 失败的，而是什么把它们从 SwiftData 的待插集合推
    /// 进 Core Data 上下文的，调查（§6）没能定位。第二次写里那一下 `profile.tabs` 是按那个
    /// 方向做的**尽力一击**——读这条关系会把 inverse 那一侧展开，理论上正是替身现形的时刻
    /// ——但在触发条件被确认之前，它仍然只是尽力，不是证明。
    func testASecondWriteStillCommitsAfterAProfileToSpaceMigration() async throws {
        let store = try makeStore()
        let fixture = try seedProfilesAndSpaces(in: store)
        for (index, name) in ["one", "two", "three"].enumerated() {
            try insertPinnedTab(
                in: store,
                guid: "pin-\(name)",
                lineageId: "lineage-\(name)",
                profile: fixture.defaultProfile,
                title: name,
                url: "https://\(name).example",
                index: index
            )
        }

        try await store.changePinnedTabScope(
            to: .space,
            preferredProfileId: "Default",
            preferredSpaceId: "space-a"
        )
        try drainMainQueue()

        XCTAssertEqual(store.pinnedTabScope(), .space)
        XCTAssertEqual(
            store.getAllPinnedTabs(for: "Default", spaceId: "space-a").count, 3
        )
        XCTAssertEqual(
            store.getAllPinnedTabs(for: "Default", spaceId: "space-b").count, 3
        )

        // 载荷①：同一个后台上下文上的**第二次**写还能提交。走 throwing 那条入口，save 失败
        // 会抛出来而不是只留一行日志。
        let target = try XCTUnwrap(
            store.getAllPinnedTabs(for: "Default", spaceId: "space-a").first
        )
        let targetGuid = target.guid
        try await store.performBackgroundWriteAndWaitThrowing { context in
            // 先把 `ProfileModel.tabs` 展开一次。那正是 `model.profile = …` 写进去的 inverse
            // 那一侧，也是替身（如果有）唯一的藏身处；读它会强制这个上下文把那一侧物化。
            // 修复之后这一下什么也读不出来，save 照常提交。
            let profiles = try context.fetch(FetchDescriptor<ProfileModel>())
            for profile in profiles {
                XCTAssertTrue(profile.tabs.allSatisfy { !$0.guid.isEmpty },
                              "inverse 那一侧没有必填列为空的替身")
            }
            let descriptor = FetchDescriptor<TabDataModel>(
                predicate: #Predicate<TabDataModel> { $0.guid == targetGuid }
            )
            let row = try XCTUnwrap(try context.fetch(descriptor).first)
            row.title = "After migration"
        }
        try drainMainQueue()

        XCTAssertEqual(store.getTab(by: targetGuid)?.title, "After migration",
                       "第二次写必须真的落盘")

        // ②是**兜底，不是载荷**：按调查的结论，替身在两种结局下都到不了盘上——save 失败
        // 什么都不写，save 成功说明当时根本没有替身。留着它是因为「空 guid 落了盘」这件事
        // 一旦真的发生，这里是唯一会喊出来的地方。真正的载荷是①。
        XCTAssertTrue(store.getAllTabs().allSatisfy { !$0.guid.isEmpty },
                      "没有任何一条必填列为空的 TabDataModel 替身")
    }

    func testProfilePinsWithoutDestinationSpaceSurviveScopeRoundTrip() async throws {
        let store = try makeStore()
        let fixture = try seedProfilesAndSpaces(in: store)
        try insertPinnedTab(
            in: store,
            guid: "work-pin",
            lineageId: "work-lineage",
            profile: fixture.workProfile,
            title: "Work",
            url: "https://work.example"
        )

        let context = try XCTUnwrap(store.getMainContext())
        let workSpace = try XCTUnwrap(
            try context.fetch(FetchDescriptor<SpaceModel>()).first(where: {
                $0.profileId == fixture.workProfile.profileId
            })
        )
        context.delete(workSpace)
        try context.save()

        try await store.changePinnedTabScope(to: .space)
        try drainMainQueue()
        XCTAssertEqual(store.pinnedTabScope(), .space)
        XCTAssertTrue(
            store.getAllPinnedTabs(for: "Work", spaceId: "missing-space").isEmpty
        )
        XCTAssertNotNil(store.getTab(by: "work-pin"))
        XCTAssertEqual(
            store.getAllTabs().filter {
                $0.dataType == .pinnedTab && $0.spaceId != nil && $0.profileId == "Work"
            }.count,
            0
        )

        try await store.changePinnedTabScope(to: .profile)
        try drainMainQueue()
        XCTAssertEqual(store.pinnedTabScope(), .profile)
        let restored = store.getAllPinnedTabs(for: "Work", spaceId: "missing-space")
        XCTAssertEqual(restored.map(\.pinLineageId), ["work-lineage"])
        XCTAssertEqual(restored.map { $0.url.absoluteString }, ["https://work.example"])
        XCTAssertTrue(restored.allSatisfy { !$0.isPinnedTabDormant })
    }

    func testSpaceToProfileRebuildDoesNotReviveStaleProfileBackup() async throws {
        let store = try makeStore()
        let fixture = try seedProfilesAndSpaces(in: store)
        try insertPinnedTab(
            in: store,
            guid: "work-pin",
            lineageId: "work-lineage",
            profile: fixture.workProfile,
            title: "Work",
            url: "https://original.example"
        )

        try await store.changePinnedTabScope(to: .space)
        try drainMainQueue()

        let context = try XCTUnwrap(store.getMainContext())
        let inactiveBackup = try XCTUnwrap(store.getTab(by: "work-pin"))
        let activeSpacePin = try XCTUnwrap(
            store.getAllPinnedTabs(for: "Work", spaceId: "space-c").first
        )
        inactiveBackup.url = try XCTUnwrap(URL(string: "https://stale-backup.example"))
        activeSpacePin.url = try XCTUnwrap(URL(string: "https://latest-space.example"))
        try context.save()

        try await store.changePinnedTabScope(to: .profile)
        try drainMainQueue()

        let rebuilt = store.getAllPinnedTabs(for: "Work", spaceId: "space-c")
        XCTAssertEqual(rebuilt.map(\.pinLineageId), ["work-lineage"])
        XCTAssertEqual(rebuilt.map { $0.url.absoluteString }, ["https://latest-space.example"])
        XCTAssertFalse(rebuilt.contains { $0.url.absoluteString == "https://stale-backup.example" })
    }

    func testDormantProfilePinsParticipateInSpaceToAppMigration() async throws {
        let store = try makeStore()
        let fixture = try seedProfilesAndSpaces(in: store)
        try insertPinnedTab(
            in: store,
            guid: "work-pin",
            lineageId: "work-lineage",
            profile: fixture.workProfile,
            title: "Dormant",
            url: "https://dormant.example"
        )

        let context = try XCTUnwrap(store.getMainContext())
        let workSpace = try XCTUnwrap(
            try context.fetch(FetchDescriptor<SpaceModel>()).first(where: {
                $0.profileId == fixture.workProfile.profileId
            })
        )
        context.delete(workSpace)
        try context.save()

        try await store.changePinnedTabScope(to: .space)
        XCTAssertEqual(store.getTab(by: "work-pin")?.isPinnedTabDormant, true)

        try await store.changePinnedTabScope(to: .app)
        try drainMainQueue()

        let appPins = store.getAllPinnedTabs(for: "Default", spaceId: "space-a")
        XCTAssertEqual(appPins.map(\.pinLineageId), ["work-lineage"])
        XCTAssertEqual(appPins.map { $0.url.absoluteString }, ["https://dormant.example"])
        XCTAssertTrue(appPins.allSatisfy { !$0.isPinnedTabDormant })
    }

    func testDeletingLastSpaceDuringSpaceScopeDoesNotReactivateProfileBackup() async throws {
        let store = try makeStore()
        let fixture = try seedProfilesAndSpaces(in: store)
        try insertPinnedTab(
            in: store,
            guid: "work-pin",
            lineageId: "work-lineage",
            profile: fixture.workProfile,
            title: "Work",
            url: "https://work.example"
        )

        try await store.changePinnedTabScope(to: .space)
        store.deleteSpaceCascade(spaceId: "space-c")
        await flushWrites(store)

        try await store.changePinnedTabScope(to: .profile)
        try drainMainQueue()

        XCTAssertTrue(
            store.getAllPinnedTabs(for: "Work", spaceId: "missing-space").isEmpty
        )
        XCTAssertNil(store.getTab(by: "work-pin"))
    }

    func testDormantProfilePinsMergeWithSpaceCreatedBeforeReturningToProfileScope() async throws {
        let store = try makeStore()
        let fixture = try seedProfilesAndSpaces(in: store)
        try insertPinnedTab(
            in: store,
            guid: "work-pin",
            lineageId: "work-lineage",
            profile: fixture.workProfile,
            title: "Dormant",
            url: "https://dormant.example"
        )

        let context = try XCTUnwrap(store.getMainContext())
        let workSpace = try XCTUnwrap(
            try context.fetch(FetchDescriptor<SpaceModel>()).first(where: {
                $0.profileId == fixture.workProfile.profileId
            })
        )
        context.delete(workSpace)
        try context.save()

        try await store.changePinnedTabScope(to: .space)
        XCTAssertEqual(store.getTab(by: "work-pin")?.isPinnedTabDormant, true)

        store.createSpace(
            profileId: "Work",
            name: "New Work",
            colorHex: "#000000",
            iconName: "star",
            spaceId: "space-new"
        )
        store.createPinnedTab(
            guid: "space-new-pin",
            url: "https://space-new.example",
            title: "Space New",
            profileId: "Work",
            spaceId: "space-new"
        )
        await flushWrites(store)

        try await store.changePinnedTabScope(to: .profile)
        try drainMainQueue()

        let merged = store.getAllPinnedTabs(for: "Work", spaceId: "space-new")
        XCTAssertEqual(Set(merged.map(\.pinLineageId)), ["work-lineage", "space-new-pin"])
        XCTAssertTrue(merged.allSatisfy { !$0.isPinnedTabDormant })
    }

    func testActiveScopeMembershipRejectsInactiveMigrationBackup() async throws {
        let store = try makeStore()
        let fixture = try seedProfilesAndSpaces(in: store)
        try insertPinnedTab(
            in: store,
            guid: "profile-pin",
            lineageId: "profile-lineage",
            profile: fixture.defaultProfile,
            title: "Profile",
            url: "https://profile.example"
        )

        try await store.changePinnedTabScope(to: .space)
        try drainMainQueue()

        let inactiveBackup = try XCTUnwrap(store.getTab(by: "profile-pin"))
        let activeCopy = try XCTUnwrap(
            store.getAllPinnedTabs(for: "Default", spaceId: "space-a").first
        )
        XCTAssertFalse(store.isPinnedTabInActiveScope(inactiveBackup))
        XCTAssertFalse(store.isPinnedTabInActiveScope(guid: inactiveBackup.guid))
        XCTAssertTrue(store.isPinnedTabInActiveScope(activeCopy))
        XCTAssertTrue(store.isPinnedTabInActiveScope(guid: activeCopy.guid))

        store.updateActivePinnedTab(
            guid: inactiveBackup.guid,
            url: try XCTUnwrap(URL(string: "https://stale-update.example")),
            title: "Stale Update"
        )
        store.removeActivePinnedTab(guid: inactiveBackup.guid)
        await flushWrites(store)

        XCTAssertEqual(store.getTab(by: inactiveBackup.guid)?.url.absoluteString, "https://profile.example")
        XCTAssertEqual(store.getTab(by: inactiveBackup.guid)?.title, "Profile")
        XCTAssertNotNil(store.getTab(by: activeCopy.guid))
    }

    func testQueuedPinnedMutationsResolveMigrationBackupGuidsInTargetOwner() async throws {
        let store = try makeStore()
        let fixture = try seedProfilesAndSpaces(in: store)
        try insertPinnedTab(
            in: store,
            guid: "profile-first",
            lineageId: "first-lineage",
            profile: fixture.defaultProfile,
            title: "First",
            url: "https://first.example",
            index: 0
        )
        try insertPinnedTab(
            in: store,
            guid: "profile-second",
            lineageId: "second-lineage",
            profile: fixture.defaultProfile,
            title: "Second",
            url: "https://second.example",
            index: 1
        )
        let staleFirst = Tab(
            url: "https://first.example",
            isActive: false,
            index: 0,
            title: "First",
            customGuid: "profile-first"
        )
        staleFirst.pinnedLineageId = "first-lineage"
        staleFirst.pinnedUrl = "https://first.example"
        staleFirst.storedTitle = "First"

        try await store.changePinnedTabScope(to: .space)

        // Model the notification handoff window: the UI still holds the old
        // profile-scoped object while its reorder and unpin writes execute
        // after the Space-scoped rows have already been committed.
        store.moveOrCreatePinnedTab(
            staleFirst,
            after: "profile-second",
            profileId: "Default",
            spaceId: "space-a"
        )
        await flushWrites(store)
        XCTAssertEqual(
            store.getAllPinnedTabs(for: "Default", spaceId: "space-a").map(\.pinLineageId),
            ["second-lineage", "first-lineage"]
        )

        store.removePinnedTab(
            staleFirst,
            profileId: "Default",
            spaceId: "space-a"
        )
        await flushWrites(store)
        XCTAssertEqual(
            store.getAllPinnedTabs(for: "Default", spaceId: "space-a").map(\.pinLineageId),
            ["second-lineage"]
        )
        XCTAssertNotNil(store.getTab(by: "profile-first"))
        XCTAssertFalse(store.isPinnedTabInActiveScope(guid: "profile-first"))
    }

    func testSpaceToProfileDeduplicatesUnchangedCopies() async throws {
        let store = try makeStore()
        let fixture = try seedProfilesAndSpaces(in: store)
        try seedPinnedSplit(in: store, profile: fixture.defaultProfile)
        try await store.changePinnedTabScope(to: .space)
        try await store.changePinnedTabScope(
            to: .profile,
            preferredProfileId: "Default",
            preferredSpaceId: "space-a"
        )
        try drainMainQueue()

        let merged = store.getAllPinnedTabs(for: "Default", spaceId: "space-a")
        XCTAssertEqual(merged.map(\.pinLineageId), ["left-lineage", "right-lineage"])
        assertSplitPair(merged)
    }

    func testSpaceToProfilePreservesDivergentSplitVariantsAsCompletePairs() async throws {
        let store = try makeStore()
        let fixture = try seedProfilesAndSpaces(in: store)
        try seedPinnedSplit(in: store, profile: fixture.defaultProfile)
        try await store.changePinnedTabScope(to: .space)
        try drainMainQueue()

        let spaceALeft = try XCTUnwrap(
            store.getAllPinnedTabs(for: "Default", spaceId: "space-a")
                .first(where: { $0.pinLineageId == "left-lineage" })
        )
        store.updateTabURL(
            spaceALeft.guid,
            url: try XCTUnwrap(URL(string: "https://space-a-changed.example"))
        )
        await flushWrites(store)

        try await store.changePinnedTabScope(
            to: .profile,
            preferredProfileId: "Default",
            preferredSpaceId: "space-a"
        )
        try drainMainQueue()

        let merged = store.getAllPinnedTabs(for: "Default", spaceId: "space-a")
        XCTAssertEqual(merged.count, 4)
        XCTAssertEqual(
            Set(merged.filter { $0.pinLineageId == "left-lineage" }.map { $0.url.absoluteString }),
            ["https://left.example", "https://space-a-changed.example"]
        )
        XCTAssertEqual(merged.filter { $0.pinLineageId == "right-lineage" }.count, 2)
        for tab in merged {
            let partnerGuid = try XCTUnwrap(tab.splitPartnerGuid)
            let partner = try XCTUnwrap(merged.first(where: { $0.guid == partnerGuid }))
            XCTAssertEqual(partner.splitPartnerGuid, tab.guid)
        }
    }

    func testProfileToAppMergesProfilesAndAppToProfileCopiesMergedCollection() async throws {
        let store = try makeStore()
        let fixture = try seedProfilesAndSpaces(in: store)
        try insertPinnedTab(
            in: store,
            guid: "default-pin",
            lineageId: "default-lineage",
            profile: fixture.defaultProfile,
            title: "Default",
            url: "https://default.example"
        )
        try insertPinnedTab(
            in: store,
            guid: "work-pin",
            lineageId: "work-lineage",
            profile: fixture.workProfile,
            title: "Work",
            url: "https://work.example"
        )

        try await store.changePinnedTabScope(
            to: .app,
            preferredProfileId: "Work",
            preferredSpaceId: "space-c"
        )
        try drainMainQueue()
        let appPins = store.getAllPinnedTabs(for: "Default", spaceId: "space-a")
        XCTAssertEqual(store.pinnedTabScope(), .app)
        XCTAssertEqual(appPins.map(\.pinLineageId), ["work-lineage", "default-lineage"])
        XCTAssertEqual(
            store.getAllPinnedTabs(for: "Work", spaceId: "space-c").map(\.guid),
            appPins.map(\.guid)
        )
        XCTAssertTrue(appPins.allSatisfy { $0.profileId == nil && $0.spaceId == nil && $0.profile == nil })

        try await store.changePinnedTabScope(to: .profile)
        try drainMainQueue()
        let defaultPins = store.getAllPinnedTabs(for: "Default", spaceId: "space-a")
        let workPins = store.getAllPinnedTabs(for: "Work", spaceId: "space-c")
        XCTAssertEqual(defaultPins.map(\.pinLineageId), appPins.map(\.pinLineageId))
        XCTAssertEqual(workPins.map(\.pinLineageId), appPins.map(\.pinLineageId))
        XCTAssertNotEqual(defaultPins.map(\.guid), workPins.map(\.guid))
        XCTAssertTrue(defaultPins.allSatisfy { $0.profileId == "Default" && $0.spaceId == nil })
        XCTAssertTrue(workPins.allSatisfy { $0.profileId == "Work" && $0.spaceId == nil })
    }

    func testAppToSpaceDirectChangeCopiesToEveryExistingSpace() async throws {
        let store = try makeStore()
        let fixture = try seedProfilesAndSpaces(in: store)
        try insertPinnedTab(
            in: store,
            guid: "app-seed",
            lineageId: "shared-lineage",
            profile: fixture.defaultProfile,
            title: "Shared",
            url: "https://shared.example"
        )
        try await store.changePinnedTabScope(to: .app)
        try await store.changePinnedTabScope(to: .space)
        try drainMainQueue()

        let a = store.getAllPinnedTabs(for: "Default", spaceId: "space-a")
        let b = store.getAllPinnedTabs(for: "Default", spaceId: "space-b")
        let c = store.getAllPinnedTabs(for: "Work", spaceId: "space-c")
        XCTAssertEqual(a.map(\.pinLineageId), ["shared-lineage"])
        XCTAssertEqual(b.map(\.pinLineageId), ["shared-lineage"])
        XCTAssertEqual(c.map(\.pinLineageId), ["shared-lineage"])
        XCTAssertEqual(Set([a[0].guid, b[0].guid, c[0].guid]).count, 3)
    }

    func testSpaceScopeNewWriteOnlyChangesItsSpaceCollection() async throws {
        let store = try makeStore()
        _ = try seedProfilesAndSpaces(in: store)
        try await store.changePinnedTabScope(to: .space)

        store.createPinnedTab(
            guid: "space-a-new",
            url: "https://new.example",
            title: "New",
            profileId: "Default",
            spaceId: "space-a"
        )
        await flushWrites(store)
        try drainMainQueue()

        XCTAssertEqual(
            store.getAllPinnedTabs(for: "Default", spaceId: "space-a").map(\.guid),
            ["space-a-new"]
        )
        XCTAssertTrue(store.getAllPinnedTabs(for: "Default", spaceId: "space-b").isEmpty)
    }

    func testSpacePublisherIgnoresOtherSpaceWritesAndEmitsAfterScopeChange() async throws {
        let store = try makeStore()
        _ = try seedProfilesAndSpaces(in: store)
        try await store.changePinnedTabScope(to: .space)
        try drainMainQueue()

        var snapshots: [[String]] = []
        store.pinnedTabsPublisher(for: "Default", spaceId: "space-a")
            .sink { snapshots.append($0.map(\.guid)) }
            .store(in: &cancellables)
        XCTAssertEqual(snapshots, [[]])

        store.createPinnedTab(
            guid: "space-b-new",
            url: "https://space-b.example",
            title: "B",
            profileId: "Default",
            spaceId: "space-b"
        )
        await flushWrites(store)
        try drainMainQueue()
        XCTAssertEqual(snapshots, [[]])

        try await store.changePinnedTabScope(
            to: .profile,
            preferredProfileId: "Default",
            preferredSpaceId: "space-b"
        )
        try waitUntil { snapshots.count == 2 && snapshots.last?.count == 1 }
        XCTAssertEqual(snapshots.last?.count, 1)
    }

    func testChangingSpaceProfileKeepsSpaceScopedPinsWithTheSpace() async throws {
        let store = try makeStore()
        _ = try seedProfilesAndSpaces(in: store)
        try await store.changePinnedTabScope(to: .space)
        store.createPinnedTab(
            guid: "space-a-pin",
            url: "https://space-a.example",
            title: "A",
            profileId: "Default",
            spaceId: "space-a"
        )
        await flushWrites(store)

        store.changeSpaceProfile(spaceId: "space-a", toProfileId: "Work")
        await flushWrites(store)
        try drainMainQueue()

        XCTAssertTrue(store.getAllPinnedTabs(for: "Default", spaceId: "space-a").isEmpty)
        let moved = store.getAllPinnedTabs(for: "Work", spaceId: "space-a")
        XCTAssertEqual(moved.map(\.guid), ["space-a-pin"])
        XCTAssertEqual(moved.first?.profileId, "Work")
        XCTAssertEqual(moved.first?.profile?.profileId, "Work")
    }

    func testDeletingSpaceRemovesOnlyItsSpaceScopedPinnedRows() async throws {
        let store = try makeStore()
        _ = try seedProfilesAndSpaces(in: store)
        try await store.changePinnedTabScope(to: .space)
        store.createPinnedTab(
            guid: "space-a-pin",
            url: "https://space-a.example",
            title: "A",
            profileId: "Default",
            spaceId: "space-a"
        )
        store.createPinnedTab(
            guid: "space-b-pin",
            url: "https://space-b.example",
            title: "B",
            profileId: "Default",
            spaceId: "space-b"
        )
        await flushWrites(store)

        store.deleteSpaceCascade(spaceId: "space-a")
        await flushWrites(store)
        try drainMainQueue()

        XCTAssertTrue(store.getAllPinnedTabs(for: "Default", spaceId: "space-a").isEmpty)
        XCTAssertEqual(
            store.getAllPinnedTabs(for: "Default", spaceId: "space-b").map(\.guid),
            ["space-b-pin"]
        )
    }

    /// CASE 8.5d — 一次带着**已有 guid** 的 create 被库拒收，而不是安静地多出一条行。
    ///
    /// 防的是什么：`guid` 在 schema 上不是唯一列，所以在这道守卫之前，同一个 guid 写两遍
    /// 是成功的。两条共享 guid 的行此后既改不动也删不掉（`.move` / `.update` / `.delete`
    /// 都按 guid 取第一条），而侧栏那本按 `guidInLocalDB` 建的字典会直接 trap
    /// （Mac B 2026-09-14 23:49）。`rowAlreadyMapped` 正是同步落地那条「这一批算错了 ⇒
    /// 整批拒收」认得的错误，于是一个字都不落库。
    func testASecondPinnedCreateOnAnExistingGuidIsRefused() async throws {
        let store = try makeStore()
        try seedProfilesAndSpaces(in: store)
        let url = try XCTUnwrap(URL(string: "https://dup.example"))

        try await store.createPinnedTabThrowing(guid: "shared-guid", url: url,
                                                title: "First", profileId: "Default")
        do {
            try await store.createPinnedTabThrowing(guid: "shared-guid", url: url,
                                                    title: "Second", profileId: "Default")
            XCTFail("第二次 create 必须抛，不许安静地多出一条行")
        } catch {
            XCTAssertEqual(error as? LocalStoreWriteError, .rowAlreadyMapped)
        }
        try drainMainQueue()

        let rows = store.getAllPinnedTabs(for: "Default")
        XCTAssertEqual(rows.filter { $0.guid == "shared-guid" }.count, 1,
                       "库里那个 guid 始终只有一条行")
        XCTAssertEqual(rows.first?.title, "First", "被拒的那一条一个字段都没写进去")
    }

    /// CASE 8.5e — 启动自愈把一个**已经**坏掉的库收拾干净。
    ///
    /// 两类各一条：共享 guid 的两行留一条（`index` 最小者），同身份的精确重复留一条。
    /// 内容分歧的变体**不动**——A11 给它们各铸一条新 lineage，删掉就是销毁用户数据。
    func testStartupSelfHealCollapsesDuplicatePinnedRows() async throws {
        let store = try makeStore()
        // `LocalStore.init` 自己排了一次自愈进写队列。空等一个 no-op 写把它排干，于是
        // 下面那次直接调用面对的是一个确定的、没人动过的库。
        await store.performBackgroundWriteAndWait { _ in }
        let fixture = try seedProfilesAndSpaces(in: store)
        // 共享 guid 的两行（Mac B 那次落地的形状：同 lineage、同内容、两个 index）。
        try insertPinnedTab(in: store, guid: "dup-guid", lineageId: "yt-lineage",
                            profile: fixture.defaultProfile, title: "YouTube",
                            url: "https://youtube.example", index: 1)
        try insertPinnedTab(in: store, guid: "dup-guid", lineageId: "yt-lineage",
                            profile: fixture.defaultProfile, title: "YouTube",
                            url: "https://youtube.example", index: 3)
        // 同一条身份的第三行，guid 不同、内容逐字相同 ⇒ 精确重复。
        try insertPinnedTab(in: store, guid: "third-guid", lineageId: "yt-lineage",
                            profile: fixture.defaultProfile, title: "YouTube",
                            url: "https://youtube.example", index: 4)
        // 同身份但**内容分歧**的变体：A11 的地盘，自愈不许碰它。
        try insertPinnedTab(in: store, guid: "variant-guid", lineageId: "yt-lineage",
                            profile: fixture.defaultProfile, title: "YouTube Renamed",
                            url: "https://youtube.example", index: 5)
        let context = try XCTUnwrap(store.getMainContext())

        let counts = try store.healDuplicatePinnedTabRowsBody(in: context)
        try context.save()

        XCTAssertEqual(counts.sharedGuid, 1, "① 共享 guid 的那一对折成一条")
        XCTAssertEqual(counts.sharedIdentity, 1, "② 同身份的精确重复也折成一条")
        let rows = store.getAllPinnedTabs(for: "Default")
        XCTAssertEqual(rows.filter { $0.guid == "dup-guid" }.count, 1,
                       "③ 那个 guid 只剩一条行")
        XCTAssertEqual(rows.first { $0.guid == "dup-guid" }?.index, 1,
                       "④ 留下的是 index 最小的那一条")
        XCTAssertNil(rows.first { $0.guid == "third-guid" },
                     "⑤ 精确重复的第三条没了")
        XCTAssertNotNil(rows.first { $0.guid == "variant-guid" },
                        "⑥ 内容分歧的变体一个字都没动")
        XCTAssertEqual(Set(rows.map(\.guid)).count, rows.count,
                       "⑦ 收尾之后没有任何两行共享 guid")
    }

    /// CASE 8.6 — a scope migration carries `contentUpdatedDate` across.
    ///
    /// 迁移过去只复制 `createdDate`，把 `contentUpdatedDate` 丢在原行上。丢掉的后果是：用户
    /// 切一次作用域，本机每一条 pin 的比较戳从「上次真实编辑」塌回 `createdDate`，于是它们
    /// 在下一轮全部输给对端任意一次旧编辑——一次作用域切换变成一次账户级的内容回滚。
    func testScopeMigrationCarriesTheContentEditTimestampToTheMigratedRow() async throws {
        let store = try makeStore()
        let fixture = try seedProfilesAndSpaces(in: store)
        let created = Date(timeIntervalSince1970: 1_000_000)
        let edited = Date(timeIntervalSince1970: 2_000_000)
        let source = try insertPinnedTab(
            in: store,
            guid: "edited-pin",
            lineageId: "edited-lineage",
            profile: fixture.defaultProfile,
            title: "Edited",
            url: "https://edited.example"
        )
        source.createdDate = created
        source.contentUpdatedDate = edited
        try XCTUnwrap(store.getMainContext()).save()

        try await store.changePinnedTabScope(
            to: .space,
            preferredProfileId: "Default",
            preferredSpaceId: "space-a"
        )
        try drainMainQueue()

        let migrated = store.getAllPinnedTabs(for: "Default", spaceId: "space-a")
        XCTAssertEqual(migrated.map(\.pinLineageId), ["edited-lineage"])
        let row = try XCTUnwrap(migrated.first)
        XCTAssertEqual(row.contentUpdatedDate, edited)
        XCTAssertEqual(row.createdDate, created)
    }

    /// CASE 8.9 — merging two copies keeps the LATER content edit stamp, not whichever copy
    /// happened to sort first.
    ///
    /// 只有内容签名相等的副本才会合并，所以合出来那一行的内容取谁都一样；它们各自的编辑戳
    /// 却可以不同。只取第一个集合那一份的话，两台把集合排成不同顺序的机器会为同一份内容发布
    /// 不同的比较戳，下一轮互相盖来盖去。取最大值与顺序无关，`lastSeen` 早就是这么取的。
    func testMergingCopiesKeepsTheLatestContentEditTimestamp() async throws {
        let store = try makeStore()
        let fixture = try seedProfilesAndSpaces(in: store)
        try insertPinnedTab(
            in: store,
            guid: "shared-pin",
            lineageId: "shared-lineage",
            profile: fixture.defaultProfile,
            title: "Shared",
            url: "https://shared.example"
        )
        try await store.changePinnedTabScope(
            to: .space,
            preferredProfileId: "Default",
            preferredSpaceId: "space-a"
        )
        try drainMainQueue()

        let early = Date(timeIntervalSince1970: 1_000_000)
        let late = Date(timeIntervalSince1970: 3_000_000)
        let inSpaceA = try XCTUnwrap(store.getAllPinnedTabs(for: "Default", spaceId: "space-a").first)
        let inSpaceB = try XCTUnwrap(store.getAllPinnedTabs(for: "Default", spaceId: "space-b").first)
        inSpaceA.contentUpdatedDate = early
        inSpaceB.contentUpdatedDate = late
        try XCTUnwrap(store.getMainContext()).save()

        try await store.changePinnedTabScope(
            to: .profile,
            preferredProfileId: "Default",
            preferredSpaceId: "space-a"
        )
        try drainMainQueue()

        let merged = store.getAllPinnedTabs(for: "Default", spaceId: "space-a")
        XCTAssertEqual(merged.map(\.pinLineageId), ["shared-lineage"])
        XCTAssertEqual(try XCTUnwrap(merged.first).contentUpdatedDate, late)
    }

    // MARK: - Fixtures

    private struct Fixture {
        let defaultProfile: ProfileModel
        let workProfile: ProfileModel
    }

    private func makeStore() throws -> LocalStore {
        let directory = try makeTemporaryDirectory()
        return LocalStore(
            account: Account(userID: UUID().uuidString),
            storeDirectoryURL: directory,
            presentsCompatibilityAlerts: false
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectories.append(directory)
        return directory
    }

    private func seedV8Store(at directory: URL) throws {
        let configuration = ModelConfiguration(
            url: directory.appendingPathComponent("LocalStore.sqlite")
        )
        let container = try ModelContainer(
            for: TabDataModelSchemaV8.ProfileModel.self,
            TabDataModelSchemaV8.TabDataModel.self,
            TabDataModelSchemaV8.SpaceModel.self,
            TabDataModelSchemaV8.SpaceURLRule.self,
            configurations: configuration
        )
        let context = container.mainContext
        let profile = TabDataModelSchemaV8.ProfileModel(profileId: "Default")
        context.insert(profile)
        let pinned = TabDataModelSchemaV8.TabDataModel(
            title: "V8",
            guid: "v8-pin",
            index: 0,
            url: try XCTUnwrap(URL(string: "https://v8.example")),
            favicon: nil,
            createdDate: Date(),
            updatedDate: Date()
        )
        pinned.type = TabDataType.pinnedTab.rawValue
        pinned.profileId = "Default"
        context.insert(pinned)
        pinned.profile = profile
        try context.save()
    }

    private func seedProfilesAndSpaces(in store: LocalStore) throws -> Fixture {
        let context = try XCTUnwrap(store.getMainContext())
        let defaultProfile = ProfileModel(profileId: "Default")
        let workProfile = ProfileModel(profileId: "Work")
        context.insert(defaultProfile)
        context.insert(workProfile)
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
        context.insert(SpaceModel(
            spaceId: "space-c",
            profileId: "Work",
            name: "C",
            colorHex: "#000000",
            iconName: "star",
            sortOrder: 2
        ))
        try context.save()
        return Fixture(defaultProfile: defaultProfile, workProfile: workProfile)
    }

    @discardableResult
    private func insertPinnedTab(
        in store: LocalStore,
        guid: String,
        lineageId: String,
        profile: ProfileModel,
        title: String,
        url: String,
        index: Int = 0,
        splitPartnerGuid: String? = nil
    ) throws -> TabDataModel {
        let context = try XCTUnwrap(store.getMainContext())
        let model = TabDataModel(
            title: title,
            guid: guid,
            index: index,
            url: try XCTUnwrap(URL(string: url)),
            favicon: nil,
            createdDate: Date(),
            updatedDate: Date()
        )
        model.dataType = .pinnedTab
        model.profileId = profile.profileId
        model.pinLineageId = lineageId
        model.splitPartnerGuid = splitPartnerGuid
        context.insert(model)
        model.profile = profile
        try context.save()
        return model
    }

    private func seedPinnedSplit(in store: LocalStore, profile: ProfileModel) throws {
        try insertPinnedTab(
            in: store,
            guid: "left-pin",
            lineageId: "left-lineage",
            profile: profile,
            title: "Left",
            url: "https://left.example",
            index: 0,
            splitPartnerGuid: "right-pin"
        )
        try insertPinnedTab(
            in: store,
            guid: "right-pin",
            lineageId: "right-lineage",
            profile: profile,
            title: "Right",
            url: "https://right.example",
            index: 1,
            splitPartnerGuid: "left-pin"
        )
    }

    private func assertSplitPair(
        _ tabs: [TabDataModel],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(tabs.count, 2, file: file, line: line)
        guard tabs.count == 2 else { return }
        XCTAssertEqual(tabs[0].splitPartnerGuid, tabs[1].guid, file: file, line: line)
        XCTAssertEqual(tabs[1].splitPartnerGuid, tabs[0].guid, file: file, line: line)
    }

    private func flushWrites(_ store: LocalStore) async {
        await store.performBackgroundWriteAndWait { _ in }
    }

    private func drainMainQueue() throws {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        condition: () -> Bool
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTFail("Condition was not met before timeout.")
    }
}

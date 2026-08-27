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

    // MARK: - Migrated pinned tabs

    /// The copies a Migration fans out over a Profile's Spaces carry one
    /// lineage, so widening the scope afterwards collapses them back into the
    /// single entry they were made from.
    func testCopiesSharingALineageCollapseWhenTheScopeWidens() async throws {
        let store = try makeStore()
        _ = try seedProfilesAndSpaces(in: store)
        try await store.changePinnedTabScope(to: .space)

        for (guid, spaceId) in [("pin-a", "space-a"), ("pin-b", "space-b")] {
            XCTAssertTrue(store.createPinnedTab(
                guid: guid,
                url: "https://pinned.example",
                title: "Pinned",
                profileId: "Default",
                spaceId: spaceId,
                lineageId: "shared-lineage"
            ))
        }
        await flushWrites(store)
        try drainMainQueue()

        try await store.changePinnedTabScope(to: .profile)
        try drainMainQueue()

        let merged = store.getAllPinnedTabs(for: "Default", spaceId: "space-a")
        XCTAssertEqual(merged.map(\.pinLineageId), ["shared-lineage"])
        // Migrated pins carry no favicon; icons arrive on first load.
        XCTAssertNil(merged.first?.favicon)
    }

    /// The lineage is the only lever the call gained: without one, a row is
    /// still its own lineage, and the scope is still whatever it was.
    func testAPinnedTabCreatedWithoutALineageKeepsItsOwnGuid() async throws {
        let store = try makeStore()
        _ = try seedProfilesAndSpaces(in: store)

        XCTAssertTrue(store.createPinnedTab(
            guid: "own-lineage-pin",
            url: "https://own.example",
            title: "Own",
            profileId: "Default",
            spaceId: "space-a"
        ))
        await flushWrites(store)
        try drainMainQueue()

        XCTAssertEqual(
            store.getAllPinnedTabs(for: "Default", spaceId: "space-a").map(\.pinLineageId),
            ["own-lineage-pin"]
        )
        XCTAssertEqual(store.pinnedTabScope(), .profile)
    }

    /// The one failure the call can report as it is made: nothing was written,
    /// so a Migration counts that entry as dropped rather than as landed.
    func testCreatingAPinnedTabFromAnUnusableURLWritesNothing() async throws {
        let store = try makeStore()
        _ = try seedProfilesAndSpaces(in: store)

        XCTAssertFalse(store.createPinnedTab(
            guid: "unusable-pin",
            url: "",
            title: "Unusable",
            profileId: "Default",
            spaceId: "space-a"
        ))
        await flushWrites(store)
        try drainMainQueue()

        XCTAssertTrue(store.getAllPinnedTabs(for: "Default", spaceId: "space-a").isEmpty)
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
        pinned.profile = profile
        pinned.profileId = "Default"
        context.insert(pinned)
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
        model.profile = profile
        model.profileId = profile.profileId
        model.pinLineageId = lineageId
        model.splitPartnerGuid = splitPartnerGuid
        context.insert(model)
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

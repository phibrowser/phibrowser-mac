// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Combine
import SwiftData
import XCTest
@testable import Phi

@MainActor
final class GuestDataMigrationTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
    }

    func testPendingGuestAccessRequiresRecoveryBeforeSourceStaging() {
        let targetUserID = "journal-target"

        XCTAssertEqual(
            GuestDataMigrationCoordinator.classifyPendingGuestAccess(
                journalPhase: .prepared,
                targetUserID: targetUserID,
                sourceDirectoryExists: true,
                tombstoneExists: false
            ),
            .requiresTargetRecovery(targetUserID: targetUserID)
        )
        XCTAssertEqual(
            GuestDataMigrationCoordinator.classifyPendingGuestAccess(
                journalPhase: .targetImported,
                targetUserID: targetUserID,
                sourceDirectoryExists: true,
                tombstoneExists: false
            ),
            .requiresTargetRecovery(targetUserID: targetUserID)
        )
        XCTAssertEqual(
            GuestDataMigrationCoordinator.classifyPendingGuestAccess(
                journalPhase: .targetImported,
                targetUserID: targetUserID,
                sourceDirectoryExists: false,
                tombstoneExists: false
            ),
            .requiresTargetRecovery(targetUserID: targetUserID)
        )
    }

    func testPendingGuestAccessAllowsFreshGuestAfterIdentityStaging() {
        let targetUserID = "journal-target"
        let deferred =
            GuestDataMigrationGuestAccessDisposition.deferredCleanup(
                targetUserID: targetUserID
            )

        XCTAssertEqual(
            GuestDataMigrationCoordinator.classifyPendingGuestAccess(
                journalPhase: .targetImported,
                targetUserID: targetUserID,
                sourceDirectoryExists: false,
                tombstoneExists: true
            ),
            deferred
        )
        XCTAssertEqual(
            GuestDataMigrationCoordinator.classifyPendingGuestAccess(
                journalPhase: .targetImported,
                targetUserID: targetUserID,
                sourceDirectoryExists: true,
                tombstoneExists: true
            ),
            deferred,
            "A source beside the old tombstone belongs to a later Guest session"
        )
        XCTAssertEqual(
            GuestDataMigrationCoordinator.classifyPendingGuestAccess(
                journalPhase: .sourceDirectoryStaged,
                targetUserID: targetUserID,
                sourceDirectoryExists: true,
                tombstoneExists: false
            ),
            deferred
        )
    }

    func testImportMergesBookmarksPinnedSplitsSpacesRulesAndRetriesWithoutDuplicates() async throws {
        let source = try makeStore(userID: "guest-source")
        let target = try makeStore(userID: "target-user")
        try seedRichGuestStore(source)
        try seedExistingTargetStore(target)

        let snapshot = try await source.makeGuestDataMigrationSnapshot(
            sourceUserID: source.account.userID,
            themes: .empty
        )
        let operationID = try XCTUnwrap(
            UUID(uuidString: "11111111-1111-1111-1111-111111111111")
        )
        let mappings = try await target.planGuestDataImport(
            snapshot,
            operationID: operationID
        )

        XCTAssertEqual(mappings.spaceIDs[LocalStore.defaultSpaceId], LocalStore.defaultSpaceId)
        XCTAssertNotEqual(mappings.spaceIDs["space-work"], "space-work")
        XCTAssertNotNil(mappings.defaultImportFolderGUID)
        XCTAssertEqual(mappings.skippedURLRules.map(\.sourceID), ["guest-default-rule"])
        XCTAssertEqual(
            mappings.pinnedTargets(for: "guest-left").count,
            2,
            "Profile-scoped Guest pins should project into both target Spaces owned by that Profile"
        )

        try await target.importGuestData(
            snapshot,
            operationID: operationID,
            targetUserID: target.account.userID,
            mappings: mappings
        )
        let receipt = GuestDataMigrationReceipt(
            operationID: operationID,
            sourceUserID: source.account.userID,
            targetUserID: target.account.userID,
            snapshotID: snapshot.snapshotID,
            completedAt: Date(),
            mappings: mappings,
            targetThemes: .empty
        )
        try await target.verifyGuestDataMigrationReceipt(
            receipt,
            snapshot: snapshot
        )
        drainMainQueue()
        let context = try XCTUnwrap(target.getMainContext())
        let importedFolderGUID = try XCTUnwrap(
            mappings.defaultImportFolderGUID
        )
        let importedFolder = try XCTUnwrap(
            context.fetch(FetchDescriptor<TabDataModel>())
                .first(where: { $0.guid == importedFolderGUID })
        )
        importedFolder.title = "User-renamed import folder"
        try context.save()
        try await target.verifyGuestDataMigrationReceipt(
            receipt,
            snapshot: snapshot
        )

        // Simulate a crash after the target transaction but before the durable
        // receipt. The same planned identifiers must turn the retry into a
        // verified no-op. Recovery identity is GUID/type/parent based, so a
        // locale change or user rename cannot invalidate the receipt.
        try await target.importGuestData(
            snapshot,
            operationID: operationID,
            targetUserID: target.account.userID,
            mappings: mappings
        )
        try await target.verifyGuestDataMigrationReceipt(
            receipt,
            snapshot: snapshot
        )

        drainMainQueue()
        let models = try context.fetch(FetchDescriptor<TabDataModel>())
        XCTAssertEqual(models.filter { $0.guid == importedFolderGUID }.count, 1)
        XCTAssertEqual(
            models.filter {
                Set(mappings.bookmarkGUIDs.values).contains($0.guid)
            }.count,
            snapshot.bookmarks.count
        )

        let insertedPins = mappings.pinnedTargets.filter(\.shouldInsert)
        XCTAssertEqual(
            models.filter {
                Set(insertedPins.map(\.targetGUID)).contains($0.guid)
            }.count,
            Set(insertedPins.map(\.targetGUID)).count
        )
        for left in mappings.pinnedTargets(for: "guest-left") {
            let right = try XCTUnwrap(
                mappings.pinnedTarget(
                    for: "guest-right",
                    profileID: left.targetProfileID,
                    spaceID: left.targetSpaceID
                )
            )
            XCTAssertEqual(left.targetSplitPartnerGUID, right.targetGUID)
            XCTAssertEqual(right.targetSplitPartnerGUID, left.targetGUID)
        }

        let spaces = try context.fetch(FetchDescriptor<SpaceModel>())
        let importedWorkSpaceID = try XCTUnwrap(mappings.spaceIDs["space-work"])
        XCTAssertEqual(
            spaces.first(where: { $0.spaceId == importedWorkSpaceID })?.profileId,
            "Work"
        )
        XCTAssertNotNil(
            spaces.first(where: { $0.spaceId == "space-work" }),
            "The target's colliding Space must remain untouched"
        )
        let importedRules = try context.fetch(FetchDescriptor<SpaceURLRule>())
        XCTAssertNotNil(importedRules.first(where: {
            $0.spaceId == LocalStore.kioskURLRuleTargetId
                && $0.host == "kiosk.example"
        }))
    }

    func testTargetCollisionAfterPlanningFailsBeforeImportAndLeavesGuestUntouched() async throws {
        let source = try makeStore(userID: "guest-collision-source")
        let target = try makeStore(userID: "collision-target")
        try seedSingleDefaultBookmark(in: source, guid: "guest-bookmark")
        try seedEmptyDefaultSpace(in: target)

        let snapshot = try await source.makeGuestDataMigrationSnapshot(
            sourceUserID: source.account.userID,
            themes: .empty
        )
        let operationID = UUID()
        let mappings = try await target.planGuestDataImport(
            snapshot,
            operationID: operationID
        )
        let targetBookmarkGUID = try XCTUnwrap(
            mappings.bookmarkGUIDs["guest-bookmark"]
        )

        let targetContext = try XCTUnwrap(target.getMainContext())
        targetContext.insert(
            makeModel(
                guid: targetBookmarkGUID,
                title: "Late collision",
                url: "https://collision.example",
                type: .tab
            )
        )
        try targetContext.save()

        do {
            try await target.importGuestData(
                snapshot,
                operationID: operationID,
                targetUserID: target.account.userID,
                mappings: mappings
            )
            XCTFail("Expected a partial-import conflict")
        } catch let error as GuestDataMigrationError {
            guard case .targetStateConflict = error else {
                return XCTFail("Unexpected migration error: \(error)")
            }
        }

        drainMainQueue()
        XCTAssertNil(
            try targetContext.fetch(FetchDescriptor<TabDataModel>())
                .first(where: {
                    $0.guid == mappings.defaultImportFolderGUID
                })
        )
        let sourceContext = try XCTUnwrap(source.getMainContext())
        XCTAssertNotNil(
            try sourceContext.fetch(FetchDescriptor<TabDataModel>())
                .first(where: { $0.guid == "guest-bookmark" })
        )
    }

    func testClosedGuestBookmarkPublisherIgnoresTargetStoreSaves() async throws {
        let source = try makeStore(userID: "guest-publisher-source")
        let target = try makeStore(userID: "guest-publisher-target")
        try seedSingleDefaultBookmark(in: source, guid: "source-bookmark")
        try seedSingleDefaultBookmark(in: target, guid: "target-bookmark")
        drainMainQueue()

        var emissions: [[String]] = []
        let cancellable = source.bookmarksPublisher(
            profileId: LocalStore.defaultProfileId
        )
        .sink { models in
            emissions.append(models.map(\.guid).sorted())
        }
        XCTAssertTrue(emissions.last?.contains("source-bookmark") == true)
        let emissionCountBeforeClose = emissions.count

        _ = try await source.makeGuestDataMigrationSnapshotAndClose(
            sourceUserID: source.account.userID,
            themes: .empty
        )
        XCTAssertNil(source.getMainContext())

        try appendDefaultBookmark(
            in: target,
            guid: "target-bookmark-after-source-close"
        )
        drainMainQueue()

        XCTAssertEqual(
            emissions.count,
            emissionCountBeforeClose,
            "A closed Guest publisher must not fetch its released context"
        )
        withExtendedLifetime(cancellable) {}
    }

    func testCoordinatorRetryUsesReceiptAndRejectsAnotherTargetIdentity() async throws {
        let defaultsRoot = try makeTemporaryDirectory()
        let source = try makeFileBackedStore(
            userID: "guest-journal-source",
            directory: defaultsRoot.appendingPathComponent("source")
        )
        let firstTarget = try makeFileBackedStore(
            userID: "target-a",
            directory: defaultsRoot.appendingPathComponent("target-a")
        )
        let secondTarget = try makeFileBackedStore(
            userID: "target-b",
            directory: defaultsRoot.appendingPathComponent("target-b")
        )
        try seedSingleDefaultBookmark(
            in: source.store,
            guid: "journal-bookmark"
        )
        try seedEmptyDefaultSpace(in: firstTarget.store)
        try seedEmptyDefaultSpace(in: secondTarget.store)

        source.defaults.setSpaceThemeIds([
            LocalStore.defaultSpaceId: "guest-theme",
        ])
        firstTarget.defaults.setSpaceThemeIds([
            LocalStore.defaultSpaceId: "target-theme",
        ])

        let journalStore = GuestDataMigrationJournalStore(
            rootURL: defaultsRoot.appendingPathComponent("journal")
        )
        let firstReceiptStore = GuestDataMigrationReceiptStore(
            rootURL: defaultsRoot.appendingPathComponent("receipts-a")
        )
        let firstReceipt = try await GuestDataMigrationCoordinator.migrate(
            sourceStore: source.store,
            sourceDefaults: source.defaults,
            sourceUserID: source.account.userID,
            targetStore: firstTarget.store,
            targetDefaults: firstTarget.defaults,
            targetUserID: firstTarget.account.userID,
            journalStore: journalStore,
            receiptStore: firstReceiptStore
        )
        XCTAssertEqual(try journalStore.load()?.phase, .targetImported)
        XCTAssertEqual(
            firstTarget.defaults.spaceThemeIds()[LocalStore.defaultSpaceId],
            "target-theme",
            "The target theme must win a mapped-Space conflict"
        )

        let reopenedSource = try makeFileBackedStore(
            userID: source.account.userID,
            directory: source.directory
        )
        let retriedReceipt = try await GuestDataMigrationCoordinator.migrate(
            sourceStore: reopenedSource.store,
            sourceDefaults: reopenedSource.defaults,
            sourceUserID: reopenedSource.account.userID,
            targetStore: firstTarget.store,
            targetDefaults: firstTarget.defaults,
            targetUserID: firstTarget.account.userID,
            journalStore: journalStore,
            receiptStore: firstReceiptStore
        )
        XCTAssertEqual(retriedReceipt, firstReceipt)

        do {
            _ = try await GuestDataMigrationCoordinator.migrate(
                sourceStore: reopenedSource.store,
                sourceDefaults: reopenedSource.defaults,
                sourceUserID: reopenedSource.account.userID,
                targetStore: secondTarget.store,
                targetDefaults: secondTarget.defaults,
                targetUserID: secondTarget.account.userID,
                journalStore: journalStore,
                receiptStore: GuestDataMigrationReceiptStore(
                    rootURL: defaultsRoot.appendingPathComponent("receipts-b")
                )
            )
            XCTFail("Expected the pending journal to reject another target")
        } catch let error as GuestDataMigrationError {
            XCTAssertEqual(
                error,
                .pendingMigrationTargetsAnotherAccount(
                    expected: "target-a",
                    actual: "target-b"
                )
            )
        }

        let inspectionSource = try makeFileBackedStore(
            userID: source.account.userID,
            directory: source.directory
        )
        let sourceContext = try XCTUnwrap(
            inspectionSource.store.getMainContext()
        )
        XCTAssertNotNil(
            try sourceContext.fetch(FetchDescriptor<TabDataModel>())
                .first(where: { $0.guid == "journal-bookmark" }),
            "Target import and receipt creation must not mutate Guest data"
        )
    }

    func testFinalizeRemovesEntireGuestDirectoryAndJournalOnlyAfterVerification() async throws {
        let root = try makeTemporaryDirectory()
        let source = try makeFileBackedStore(
            userID: Account.defaultUid,
            directory: root
                .appendingPathComponent("users", isDirectory: true)
                .appendingPathComponent(Account.defaultUid, isDirectory: true)
        )
        let target = try makeFileBackedStore(
            userID: "cleanup-target",
            directory: root
                .appendingPathComponent("users", isDirectory: true)
                .appendingPathComponent("cleanup-target", isDirectory: true)
        )
        try seedSingleDefaultBookmark(
            in: source.store,
            guid: "cleanup-bookmark"
        )
        try seedEmptyDefaultSpace(in: target.store)

        let excludedFile = source.directory.appendingPathComponent(
            "excluded-guest-state.bin"
        )
        try Data("preserve-until-verified".utf8).write(to: excludedFile)
        let journalStore = GuestDataMigrationJournalStore(
            rootURL: root.appendingPathComponent("journal")
        )
        let receiptStore = GuestDataMigrationReceiptStore(
            rootURL: target.directory.appendingPathComponent("receipts")
        )
        let receipt = try await GuestDataMigrationCoordinator.migrate(
            sourceStore: source.store,
            sourceDefaults: source.defaults,
            sourceUserID: source.account.userID,
            targetStore: target.store,
            targetDefaults: target.defaults,
            targetUserID: target.account.userID,
            journalStore: journalStore,
            receiptStore: receiptStore
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: excludedFile.path))
        XCTAssertEqual(try journalStore.load()?.phase, .targetImported)

        try await GuestDataMigrationCoordinator
            .finalizeSourceDirectoryCleanup(
                receipt: receipt,
                sourceUserID: source.account.userID,
                sourceDirectory: source.directory,
                targetStore: target.store,
                targetDefaults: target.defaults,
                targetUserID: target.account.userID,
                journalStore: journalStore,
                receiptStore: receiptStore
            )

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: source.directory.path),
            "Successful cleanup must remove the complete Guest directory"
        )
        XCTAssertNil(try journalStore.load())
        XCTAssertEqual(
            try receiptStore.load(operationID: receipt.operationID),
            receipt,
            "The target receipt remains as durable import evidence"
        )
    }

    func testStagedTombstoneAndRecreatedSourceStartsFollowUpMigration() async throws {
        let root = try makeTemporaryDirectory()
        let sourceDirectory = root
            .appendingPathComponent("users", isDirectory: true)
            .appendingPathComponent(Account.defaultUid, isDirectory: true)
        let source = try makeFileBackedStore(
            userID: Account.defaultUid,
            directory: sourceDirectory
        )
        let target = try makeFileBackedStore(
            userID: "staged-target",
            directory: root
                .appendingPathComponent("users", isDirectory: true)
                .appendingPathComponent("staged-target", isDirectory: true)
        )
        try seedSingleDefaultBookmark(
            in: source.store,
            guid: "before-staging"
        )
        try seedEmptyDefaultSpace(in: target.store)

        let journalStore = GuestDataMigrationJournalStore(
            rootURL: root.appendingPathComponent("journal")
        )
        let receiptStore = GuestDataMigrationReceiptStore(
            rootURL: target.directory.appendingPathComponent("receipts")
        )
        let firstReceipt = try await GuestDataMigrationCoordinator.migrate(
            sourceStore: source.store,
            sourceDefaults: source.defaults,
            sourceUserID: source.account.userID,
            targetStore: target.store,
            targetDefaults: target.defaults,
            targetUserID: target.account.userID,
            journalStore: journalStore,
            receiptStore: receiptStore
        )

        try await source.store.closeForAccountDirectoryRemoval()
        let cleanupPaths = GuestDataMigrationCoordinator
            .sourceDirectoryCleanupPaths(
                sourceDirectory: sourceDirectory,
                operationID: firstReceipt.operationID
            )
        try FileManager.default.moveItem(
            at: cleanupPaths.source,
            to: cleanupPaths.tombstone
        )
        var stagedJournal = try XCTUnwrap(journalStore.load())
        stagedJournal.phase = .sourceDirectoryStaged
        try journalStore.write(stagedJournal)

        let recreatedSource = try makeFileBackedStore(
            userID: Account.defaultUid,
            directory: sourceDirectory
        )
        try seedSingleDefaultBookmark(
            in: recreatedSource.store,
            guid: "after-staging"
        )

        let stagedReceipt = try await GuestDataMigrationCoordinator
            .recoverStagedCleanupIfNeeded(
                sourceUserID: recreatedSource.account.userID,
                targetUserID: target.account.userID,
                targetStore: target.store,
                targetDefaults: target.defaults,
                sourceDirectory: sourceDirectory,
                journalStore: journalStore,
                receiptStore: receiptStore
            )
        XCTAssertNil(stagedReceipt)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: cleanupPaths.tombstone.path)
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: sourceDirectory.path),
            "Recovery must never delete a source directory recreated after staging"
        )
        XCTAssertNil(try journalStore.load())

        let followUpReceipt = try await GuestDataMigrationCoordinator.migrate(
            sourceStore: recreatedSource.store,
            sourceDefaults: recreatedSource.defaults,
            sourceUserID: recreatedSource.account.userID,
            targetStore: target.store,
            targetDefaults: target.defaults,
            targetUserID: target.account.userID,
            journalStore: journalStore,
            receiptStore: receiptStore
        )
        XCTAssertNotEqual(
            followUpReceipt.operationID,
            firstReceipt.operationID
        )
        XCTAssertEqual(try journalStore.load()?.phase, .targetImported)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceDirectory.path))
    }

    func testStagedSourceAbsentFinalizesWithoutRecreatingGuestDirectory() async throws {
        let root = try makeTemporaryDirectory()
        let sourceDirectory = root
            .appendingPathComponent("users", isDirectory: true)
            .appendingPathComponent(Account.defaultUid, isDirectory: true)
        let source = try makeFileBackedStore(
            userID: Account.defaultUid,
            directory: sourceDirectory
        )
        let target = try makeFileBackedStore(
            userID: "absent-source-target",
            directory: root
                .appendingPathComponent("users", isDirectory: true)
                .appendingPathComponent(
                    "absent-source-target",
                    isDirectory: true
                )
        )
        try seedSingleDefaultBookmark(
            in: source.store,
            guid: "absent-source-bookmark"
        )
        try seedEmptyDefaultSpace(in: target.store)

        let journalStore = GuestDataMigrationJournalStore(
            rootURL: root.appendingPathComponent("journal")
        )
        let receiptStore = GuestDataMigrationReceiptStore(
            rootURL: target.directory.appendingPathComponent("receipts")
        )
        let receipt = try await GuestDataMigrationCoordinator.migrate(
            sourceStore: source.store,
            sourceDefaults: source.defaults,
            sourceUserID: source.account.userID,
            targetStore: target.store,
            targetDefaults: target.defaults,
            targetUserID: target.account.userID,
            journalStore: journalStore,
            receiptStore: receiptStore
        )
        let cleanupPaths = GuestDataMigrationCoordinator
            .sourceDirectoryCleanupPaths(
                sourceDirectory: sourceDirectory,
                operationID: receipt.operationID
            )
        try FileManager.default.moveItem(
            at: cleanupPaths.source,
            to: cleanupPaths.tombstone
        )
        var stagedJournal = try XCTUnwrap(journalStore.load())
        stagedJournal.phase = .sourceDirectoryStaged
        try journalStore.write(stagedJournal)

        let recoveredReceipt = try await GuestDataMigrationCoordinator
            .recoverStagedCleanupIfNeeded(
                sourceUserID: source.account.userID,
                targetUserID: target.account.userID,
                targetStore: target.store,
                targetDefaults: target.defaults,
                sourceDirectory: sourceDirectory,
                journalStore: journalStore,
                receiptStore: receiptStore
            )
        XCTAssertEqual(recoveredReceipt, receipt)

        try await GuestDataMigrationCoordinator
            .finalizeSourceDirectoryCleanup(
                receipt: try XCTUnwrap(recoveredReceipt),
                sourceUserID: source.account.userID,
                sourceDirectory: sourceDirectory,
                targetStore: target.store,
                targetDefaults: target.defaults,
                targetUserID: target.account.userID,
                journalStore: journalStore,
                receiptStore: receiptStore
            )

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: sourceDirectory.path)
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: cleanupPaths.tombstone.path)
        )
        XCTAssertNil(try journalStore.load())
    }

    func testTargetImportedTombstoneOnlyCrashAdvancesRecoveryWithoutRecreatingGuestDirectory() async throws {
        let root = try makeTemporaryDirectory()
        let sourceDirectory = root
            .appendingPathComponent("users", isDirectory: true)
            .appendingPathComponent(Account.defaultUid, isDirectory: true)
        let source = try makeFileBackedStore(
            userID: Account.defaultUid,
            directory: sourceDirectory
        )
        let target = try makeFileBackedStore(
            userID: "move-crash-target",
            directory: root
                .appendingPathComponent("users", isDirectory: true)
                .appendingPathComponent(
                    "move-crash-target",
                    isDirectory: true
                )
        )
        try seedSingleDefaultBookmark(
            in: source.store,
            guid: "move-crash-bookmark"
        )
        try seedEmptyDefaultSpace(in: target.store)

        let journalStore = GuestDataMigrationJournalStore(
            rootURL: root.appendingPathComponent("journal")
        )
        let receiptStore = GuestDataMigrationReceiptStore(
            rootURL: target.directory.appendingPathComponent("receipts")
        )
        let receipt = try await GuestDataMigrationCoordinator.migrate(
            sourceStore: source.store,
            sourceDefaults: source.defaults,
            sourceUserID: source.account.userID,
            targetStore: target.store,
            targetDefaults: target.defaults,
            targetUserID: target.account.userID,
            journalStore: journalStore,
            receiptStore: receiptStore
        )
        XCTAssertEqual(try journalStore.load()?.phase, .targetImported)

        let cleanupPaths = GuestDataMigrationCoordinator
            .sourceDirectoryCleanupPaths(
                sourceDirectory: sourceDirectory,
                operationID: receipt.operationID
            )
        try FileManager.default.moveItem(
            at: cleanupPaths.source,
            to: cleanupPaths.tombstone
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: sourceDirectory.path)
        )

        let recoveredReceipt = try await GuestDataMigrationCoordinator
            .recoverStagedCleanupIfNeeded(
                sourceUserID: source.account.userID,
                targetUserID: target.account.userID,
                targetStore: target.store,
                targetDefaults: target.defaults,
                sourceDirectory: sourceDirectory,
                journalStore: journalStore,
                receiptStore: receiptStore
            )
        XCTAssertEqual(recoveredReceipt, receipt)
        XCTAssertEqual(
            try journalStore.load()?.phase,
            .sourceDirectoryStaged
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: sourceDirectory.path),
            "Recovery must not instantiate an empty Guest store"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: cleanupPaths.tombstone.path)
        )

        try await GuestDataMigrationCoordinator
            .finalizeSourceDirectoryCleanup(
                receipt: try XCTUnwrap(recoveredReceipt),
                sourceUserID: source.account.userID,
                sourceDirectory: sourceDirectory,
                targetStore: target.store,
                targetDefaults: target.defaults,
                targetUserID: target.account.userID,
                journalStore: journalStore,
                receiptStore: receiptStore
            )

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: sourceDirectory.path)
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: cleanupPaths.tombstone.path)
        )
        XCTAssertNil(try journalStore.load())
    }

    func testTerminalSnapshotRetryPreservesSourceAndRejectsOutOfBandWrites() async throws {
        let root = try makeTemporaryDirectory()
        let source = try makeFileBackedStore(
            userID: Account.defaultUid,
            directory: root
                .appendingPathComponent("users", isDirectory: true)
                .appendingPathComponent(Account.defaultUid, isDirectory: true)
        )
        let target = try makeFileBackedStore(
            userID: "retry-target",
            directory: root
                .appendingPathComponent("users", isDirectory: true)
                .appendingPathComponent("retry-target", isDirectory: true)
        )
        try seedSingleDefaultBookmark(
            in: source.store,
            guid: "snapshot-bookmark"
        )
        try seedEmptyDefaultSpace(in: target.store)

        let journalStore = GuestDataMigrationJournalStore(
            rootURL: root.appendingPathComponent("journal")
        )
        let receiptStore = GuestDataMigrationReceiptStore(
            rootURL: target.directory.appendingPathComponent("receipts")
        )
        let receipt = try await GuestDataMigrationCoordinator.migrate(
            sourceStore: source.store,
            sourceDefaults: source.defaults,
            sourceUserID: source.account.userID,
            targetStore: target.store,
            targetDefaults: target.defaults,
            targetUserID: target.account.userID,
            journalStore: journalStore,
            receiptStore: receiptStore
        )
        XCTAssertNil(
            source.store.getMainContext(),
            "Migration must seal the Guest store before target publication"
        )

        let retrySource = try makeFileBackedStore(
            userID: source.account.userID,
            directory: source.directory
        )
        let retryReceipt = try await GuestDataMigrationCoordinator.migrate(
            sourceStore: retrySource.store,
            sourceDefaults: retrySource.defaults,
            sourceUserID: retrySource.account.userID,
            targetStore: target.store,
            targetDefaults: target.defaults,
            targetUserID: target.account.userID,
            journalStore: journalStore,
            receiptStore: receiptStore
        )
        XCTAssertEqual(retryReceipt, receipt)
        XCTAssertNil(retrySource.store.getMainContext())
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: source.directory.path)
        )
        XCTAssertEqual(try journalStore.load()?.phase, .targetImported)

        let mutatedSource = try makeFileBackedStore(
            userID: source.account.userID,
            directory: source.directory
        )
        let sourceContext = try XCTUnwrap(
            mutatedSource.store.getMainContext()
        )
        sourceContext.insert(
            makeModel(
                guid: "post-snapshot-bookmark",
                title: "Written after import",
                url: "https://post-snapshot.example",
                type: .bookmark
            )
        )
        try sourceContext.save()

        do {
            _ = try await GuestDataMigrationCoordinator.migrate(
                sourceStore: mutatedSource.store,
                sourceDefaults: mutatedSource.defaults,
                sourceUserID: mutatedSource.account.userID,
                targetStore: target.store,
                targetDefaults: target.defaults,
                targetUserID: target.account.userID,
                journalStore: journalStore,
                receiptStore: receiptStore
            )
            XCTFail("Expected post-snapshot Guest data to block retry")
        } catch let error as GuestDataMigrationError {
            XCTAssertEqual(error, .sourceDataChangedAfterSnapshot)
        }

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: source.directory.path),
            "An invariant violation must preserve the complete Guest source"
        )
        XCTAssertEqual(try journalStore.load()?.phase, .targetImported)
    }

    func testUntouchedTargetFailureReturnsToWritableGuestAndNextLoginUsesFreshSnapshot() async throws {
        let root = try makeTemporaryDirectory()
        let source = try makeFileBackedStore(
            userID: Account.defaultUid,
            directory: root
                .appendingPathComponent("users", isDirectory: true)
                .appendingPathComponent(Account.defaultUid, isDirectory: true)
        )
        let target = try makeFileBackedStore(
            userID: "fresh-retry-target",
            directory: root
                .appendingPathComponent("users", isDirectory: true)
                .appendingPathComponent(
                    "fresh-retry-target",
                    isDirectory: true
                )
        )
        try seedSingleDefaultBookmark(
            in: source.store,
            guid: "before-failed-login"
        )
        try seedEmptyDefaultSpace(in: target.store)

        let snapshot = try await source.store
            .makeGuestDataMigrationSnapshotAndClose(
                sourceUserID: source.account.userID,
                themes: .empty
            )
        let failedOperationID = UUID()
        let validMappings = try await target.store.planGuestDataImport(
            snapshot,
            operationID: failedOperationID
        )
        var invalidBookmarkGUIDs = validMappings.bookmarkGUIDs
        invalidBookmarkGUIDs.removeValue(forKey: "before-failed-login")
        let invalidMappings = GuestDataMigrationIdentifierMappings(
            profileIDs: validMappings.profileIDs,
            spaceIDs: validMappings.spaceIDs,
            bookmarkGUIDs: invalidBookmarkGUIDs,
            pinnedTargets: validMappings.pinnedTargets,
            pinLineageIDs: validMappings.pinLineageIDs,
            urlRuleTargets: validMappings.urlRuleTargets,
            skippedURLRules: validMappings.skippedURLRules,
            defaultImportFolderGUID: validMappings.defaultImportFolderGUID,
            targetPinnedTabScopeRawValue:
                validMappings.targetPinnedTabScopeRawValue,
            targetSpaceProfileIDs: validMappings.targetSpaceProfileIDs,
            insertedProfileIDs: validMappings.insertedProfileIDs,
            insertedSpaceIDs: validMappings.insertedSpaceIDs
        )
        let journalStore = GuestDataMigrationJournalStore(
            rootURL: root.appendingPathComponent("journal")
        )
        let receiptStore = GuestDataMigrationReceiptStore(
            rootURL: target.directory.appendingPathComponent("receipts")
        )
        try journalStore.write(
            GuestDataMigrationJournal(
                operationID: failedOperationID,
                sourceUserID: source.account.userID,
                targetUserID: target.account.userID,
                snapshot: snapshot,
                mappings: invalidMappings,
                phase: .prepared,
                receipt: nil
            )
        )

        do {
            _ = try await GuestDataMigrationCoordinator.migrate(
                sourceStore: source.store,
                sourceDefaults: source.defaults,
                sourceUserID: source.account.userID,
                targetStore: target.store,
                targetDefaults: target.defaults,
                targetUserID: target.account.userID,
                journalStore: journalStore,
                receiptStore: receiptStore,
                sourceAlreadySealed: true
            )
            XCTFail("Expected the incomplete prepared plan to fail")
        } catch let error as GuestDataMigrationError {
            guard case .targetStateConflict = error else {
                return XCTFail("Unexpected migration error: \(error)")
            }
        }

        let canResumeGuest = try await GuestDataMigrationCoordinator
            .discardPreparedMigrationIfTargetUntouched(
                targetStore: target.store,
                targetUserID: target.account.userID,
                journalStore: journalStore
            )
        XCTAssertTrue(
            canResumeGuest
        )
        XCTAssertNil(
            try journalStore.load(),
            "A failed pre-import snapshot must not trap future Guest edits"
        )

        let writableGuest = try makeFileBackedStore(
            userID: source.account.userID,
            directory: source.directory
        )
        XCTAssertNotNil(writableGuest.store.getMainContext())
        try appendDefaultBookmark(
            in: writableGuest.store,
            guid: "after-failed-login"
        )

        let retryReceipt = try await GuestDataMigrationCoordinator.migrate(
            sourceStore: writableGuest.store,
            sourceDefaults: writableGuest.defaults,
            sourceUserID: writableGuest.account.userID,
            targetStore: target.store,
            targetDefaults: target.defaults,
            targetUserID: target.account.userID,
            journalStore: journalStore,
            receiptStore: receiptStore
        )
        XCTAssertNotEqual(retryReceipt.operationID, failedOperationID)
        let retriedJournal = try XCTUnwrap(journalStore.load())
        XCTAssertEqual(retriedJournal.phase, .targetImported)
        XCTAssertEqual(
            Set(retriedJournal.snapshot.bookmarks.map(\.guid)),
            ["before-failed-login", "after-failed-login"]
        )
    }

    func testPostImportFailureKeepsGuestSealedAndRetriesSameTargetWithoutDuplicates() async throws {
        let root = try makeTemporaryDirectory()
        let source = try makeFileBackedStore(
            userID: Account.defaultUid,
            directory: root
                .appendingPathComponent("users", isDirectory: true)
                .appendingPathComponent(Account.defaultUid, isDirectory: true)
        )
        let target = try makeFileBackedStore(
            userID: "post-import-retry-target",
            directory: root
                .appendingPathComponent("users", isDirectory: true)
                .appendingPathComponent(
                    "post-import-retry-target",
                    isDirectory: true
                )
        )
        try seedSingleDefaultBookmark(
            in: source.store,
            guid: "post-import-bookmark"
        )
        try seedEmptyDefaultSpace(in: target.store)

        let journalStore = GuestDataMigrationJournalStore(
            rootURL: root.appendingPathComponent("journal")
        )
        let receiptStore = GuestDataMigrationReceiptStore(
            rootURL: target.directory.appendingPathComponent("receipts")
        )
        let invalidDefaultsURL = root.appendingPathComponent(
            "defaults-write-blocker",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: invalidDefaultsURL,
            withIntermediateDirectories: true
        )
        let invalidTargetDefaults = AccountUserDefaults(
            account: target.account,
            storeURL: invalidDefaultsURL
        )

        do {
            _ = try await GuestDataMigrationCoordinator.migrate(
                sourceStore: source.store,
                sourceDefaults: source.defaults,
                sourceUserID: source.account.userID,
                targetStore: target.store,
                targetDefaults: invalidTargetDefaults,
                targetUserID: target.account.userID,
                journalStore: journalStore,
                receiptStore: receiptStore
            )
            XCTFail("Expected target defaults persistence to fail")
        } catch {
            XCTAssertFalse(error is GuestDataMigrationError)
        }

        XCTAssertNil(
            source.store.getMainContext(),
            "Target-touched failures must keep the old Guest store terminal"
        )
        XCTAssertEqual(try journalStore.load()?.phase, .prepared)
        let canResumeGuest = try await GuestDataMigrationCoordinator
            .discardPreparedMigrationIfTargetUntouched(
                targetStore: target.store,
                targetUserID: target.account.userID,
                journalStore: journalStore
            )
        XCTAssertFalse(
            canResumeGuest,
            "A committed target import must never return to editable Guest"
        )

        let receipt = try await GuestDataMigrationCoordinator.migrate(
            sourceStore: source.store,
            sourceDefaults: source.defaults,
            sourceUserID: source.account.userID,
            targetStore: target.store,
            targetDefaults: target.defaults,
            targetUserID: target.account.userID,
            journalStore: journalStore,
            receiptStore: receiptStore,
            sourceAlreadySealed: true
        )
        XCTAssertEqual(try journalStore.load()?.phase, .targetImported)

        drainMainQueue()
        let context = try XCTUnwrap(target.store.getMainContext())
        let importedGUID = try XCTUnwrap(
            receipt.mappings.bookmarkGUIDs["post-import-bookmark"]
        )
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<TabDataModel>())
                .filter { $0.guid == importedGUID }.count,
            1
        )
    }

    // MARK: - Fixtures

    private struct FileBackedStore {
        let account: Account
        let store: LocalStore
        let defaults: AccountUserDefaults
        let directory: URL
    }

    private func makeFileBackedStore(
        userID: String,
        directory: URL
    ) throws -> FileBackedStore {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let account = Account(userID: userID)
        return FileBackedStore(
            account: account,
            store: LocalStore(
                account: account,
                storeDirectoryURL: directory.appendingPathComponent(
                    "localDB",
                    isDirectory: true
                ),
                presentsCompatibilityAlerts: false
            ),
            defaults: AccountUserDefaults(
                account: account,
                storeURL: directory
                    .appendingPathComponent("defaults", isDirectory: true)
                    .appendingPathComponent("account_defaults.plist")
            ),
            directory: directory
        )
    }

    private func makeStore(userID: String) throws -> LocalStore {
        let directory = try makeTemporaryDirectory()
        return LocalStore(
            account: Account(userID: userID),
            storeDirectoryURL: directory,
            presentsCompatibilityAlerts: false
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = URL(
            fileURLWithPath: NSTemporaryDirectory(),
            isDirectory: true
        ).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        temporaryDirectories.append(directory)
        return directory
    }

    private func seedRichGuestStore(_ store: LocalStore) throws {
        let context = try XCTUnwrap(store.getMainContext())
        let defaultProfile = ProfileModel(
            profileId: LocalStore.defaultProfileId,
            displayName: "Personal"
        )
        let workProfile = ProfileModel(
            profileId: "Work",
            displayName: "Work"
        )
        context.insert(defaultProfile)
        context.insert(workProfile)

        let defaultSpace = SpaceModel(
            spaceId: LocalStore.defaultSpaceId,
            profileId: LocalStore.defaultProfileId,
            name: "Default",
            colorHex: "#111111",
            iconName: "house",
            sortOrder: 0
        )
        let workSpace = SpaceModel(
            spaceId: "space-work",
            profileId: "Work",
            name: "Guest Work",
            colorHex: "#222222",
            iconName: "briefcase",
            sortOrder: 1
        )
        context.insert(defaultSpace)
        context.insert(workSpace)

        let defaultRoot = makeFolder(
            guid: "guest-default-root",
            title: "Bookmarks",
            profile: defaultProfile,
            spaceID: LocalStore.defaultSpaceId
        )
        defaultProfile.bookmarkRoot = defaultRoot
        defaultSpace.bookmarkRoot = defaultRoot
        context.insert(defaultRoot)
        let folder = makeFolder(
            guid: "guest-folder",
            title: "Folder",
            profile: defaultProfile,
            spaceID: LocalStore.defaultSpaceId
        )
        folder.parent = defaultRoot
        context.insert(folder)
        let nestedBookmark = makeModel(
            guid: "guest-nested",
            title: "Nested",
            url: "https://nested.example",
            type: .bookmark
        )
        nestedBookmark.profile = defaultProfile
        nestedBookmark.profileId = defaultProfile.profileId
        nestedBookmark.spaceId = defaultSpace.spaceId
        nestedBookmark.parent = folder
        nestedBookmark.secondaryUrl = URL(
            string: "https://nested-secondary.example"
        )
        context.insert(nestedBookmark)

        let workRoot = makeFolder(
            guid: "guest-work-root",
            title: "Bookmarks",
            profile: workProfile,
            spaceID: workSpace.spaceId
        )
        workSpace.bookmarkRoot = workRoot
        context.insert(workRoot)
        let workBookmark = makeModel(
            guid: "guest-work-bookmark",
            title: "Work",
            url: "https://work.example",
            type: .bookmark
        )
        workBookmark.profile = workProfile
        workBookmark.profileId = workProfile.profileId
        workBookmark.spaceId = workSpace.spaceId
        workBookmark.parent = workRoot
        context.insert(workBookmark)

        let left = makeModel(
            guid: "guest-left",
            title: "Left",
            url: "https://left.example",
            type: .pinnedTab
        )
        left.profile = defaultProfile
        left.profileId = defaultProfile.profileId
        left.pinLineageId = "left-lineage"
        left.splitPartnerGuid = "guest-right"
        context.insert(left)
        let right = makeModel(
            guid: "guest-right",
            title: "Right",
            url: "https://right.example",
            type: .pinnedTab
        )
        right.index = 1
        right.profile = defaultProfile
        right.profileId = defaultProfile.profileId
        right.pinLineageId = "right-lineage"
        right.splitPartnerGuid = "guest-left"
        context.insert(right)

        context.insert(
            SpaceURLRule(
                id: "guest-default-rule",
                spaceId: LocalStore.defaultSpaceId,
                host: "existing.example",
                pathPrefix: "/same",
                sortOrder: 0
            )
        )
        context.insert(
            SpaceURLRule(
                id: "guest-work-rule",
                spaceId: workSpace.spaceId,
                host: "work.example",
                sortOrder: 0
            )
        )
        context.insert(
            SpaceURLRule(
                id: "guest-kiosk-rule",
                spaceId: LocalStore.kioskURLRuleTargetId,
                host: "kiosk.example",
                sortOrder: 0
            )
        )
        context.insert(
            BrowserDataSettingsModel(
                pinnedTabScopeRawValue: PinnedTabScope.profile.rawValue
            )
        )
        try context.save()
    }

    private func seedExistingTargetStore(_ store: LocalStore) throws {
        let context = try XCTUnwrap(store.getMainContext())
        let defaultProfile = ProfileModel(
            profileId: LocalStore.defaultProfileId
        )
        context.insert(defaultProfile)
        let defaultSpace = SpaceModel(
            spaceId: LocalStore.defaultSpaceId,
            profileId: defaultProfile.profileId,
            name: "Target Default",
            colorHex: "#AAAAAA",
            iconName: "target",
            sortOrder: 0
        )
        let collidingSpace = SpaceModel(
            spaceId: "space-work",
            profileId: defaultProfile.profileId,
            name: "Target Collision",
            colorHex: "#BBBBBB",
            iconName: "target",
            sortOrder: 1
        )
        context.insert(defaultSpace)
        context.insert(collidingSpace)
        let root = makeFolder(
            guid: "target-default-root",
            title: "Bookmarks",
            profile: defaultProfile,
            spaceID: defaultSpace.spaceId
        )
        defaultProfile.bookmarkRoot = root
        defaultSpace.bookmarkRoot = root
        context.insert(root)
        let existingPin = makeModel(
            guid: "target-pin",
            title: "Target",
            url: "https://target.example",
            type: .pinnedTab
        )
        existingPin.profile = defaultProfile
        existingPin.profileId = defaultProfile.profileId
        existingPin.spaceId = defaultSpace.spaceId
        existingPin.pinLineageId = existingPin.guid
        context.insert(existingPin)
        context.insert(
            SpaceURLRule(
                id: "target-rule",
                spaceId: defaultSpace.spaceId,
                host: "existing.example",
                pathPrefix: "/same",
                sortOrder: 0
            )
        )
        context.insert(
            BrowserDataSettingsModel(
                pinnedTabScopeRawValue: PinnedTabScope.space.rawValue
            )
        )
        try context.save()
    }

    private func seedSingleDefaultBookmark(
        in store: LocalStore,
        guid: String
    ) throws {
        let context = try XCTUnwrap(store.getMainContext())
        let profile = ProfileModel(profileId: LocalStore.defaultProfileId)
        let space = SpaceModel(
            spaceId: LocalStore.defaultSpaceId,
            profileId: profile.profileId,
            name: "Default",
            colorHex: "#111111",
            iconName: "house",
            sortOrder: 0
        )
        context.insert(profile)
        context.insert(space)
        let root = makeFolder(
            guid: "\(guid)-root",
            title: "Bookmarks",
            profile: profile,
            spaceID: space.spaceId
        )
        profile.bookmarkRoot = root
        space.bookmarkRoot = root
        context.insert(root)
        let bookmark = makeModel(
            guid: guid,
            title: "Guest",
            url: "https://guest.example",
            type: .bookmark
        )
        bookmark.profile = profile
        bookmark.profileId = profile.profileId
        bookmark.spaceId = space.spaceId
        bookmark.parent = root
        context.insert(bookmark)
        context.insert(BrowserDataSettingsModel())
        try context.save()
    }

    private func seedEmptyDefaultSpace(in store: LocalStore) throws {
        let context = try XCTUnwrap(store.getMainContext())
        let profile = ProfileModel(profileId: LocalStore.defaultProfileId)
        let space = SpaceModel(
            spaceId: LocalStore.defaultSpaceId,
            profileId: profile.profileId,
            name: "Default",
            colorHex: "#AAAAAA",
            iconName: "house",
            sortOrder: 0
        )
        context.insert(profile)
        context.insert(space)
        let root = makeFolder(
            guid: UUID().uuidString,
            title: "Bookmarks",
            profile: profile,
            spaceID: space.spaceId
        )
        profile.bookmarkRoot = root
        space.bookmarkRoot = root
        context.insert(root)
        context.insert(BrowserDataSettingsModel())
        try context.save()
    }

    private func appendDefaultBookmark(
        in store: LocalStore,
        guid: String
    ) throws {
        let context = try XCTUnwrap(store.getMainContext())
        let profileID = LocalStore.defaultProfileId
        let spaceID = LocalStore.defaultSpaceId
        let profile = try XCTUnwrap(
            context.fetch(FetchDescriptor<ProfileModel>())
                .first(where: { $0.profileId == profileID })
        )
        let root = try XCTUnwrap(profile.bookmarkRoot)
        let bookmark = makeModel(
            guid: guid,
            title: "Guest after failure",
            url: "https://guest-after-failure.example",
            type: .bookmark
        )
        bookmark.profile = profile
        bookmark.profileId = profileID
        bookmark.spaceId = spaceID
        bookmark.parent = root
        context.insert(bookmark)
        try context.save()
    }

    private func makeFolder(
        guid: String,
        title: String,
        profile: ProfileModel,
        spaceID: String
    ) -> TabDataModel {
        let folder = makeModel(
            guid: guid,
            title: title,
            url: "https://bookmark.phi/folder",
            type: .bookmarkFolder
        )
        folder.profile = profile
        folder.profileId = profile.profileId
        folder.spaceId = spaceID
        return folder
    }

    private func makeModel(
        guid: String,
        title: String,
        url: String,
        type: TabDataType
    ) -> TabDataModel {
        let now = Date()
        let model = TabDataModel(
            title: title,
            guid: guid,
            index: 0,
            url: URL(string: url)!,
            favicon: nil,
            createdDate: now,
            updatedDate: now
        )
        model.dataType = type
        return model
    }

    private func drainMainQueue() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
}

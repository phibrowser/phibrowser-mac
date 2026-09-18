// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
import SwiftData
@testable import Phi

@MainActor
final class LocalStoreCompatibilityTests: XCTestCase {
    private var tempDirectories: [URL] = []

    override func tearDownWithError() throws {
        let fileManager = FileManager.default
        for directory in tempDirectories {
            try? fileManager.removeItem(at: directory)
        }
        tempDirectories.removeAll()
    }

    func testFirstRunCreatesManifestForCurrentStoreFormat() throws {
        let directory = try makeTemporaryStoreDirectory()
        let controller = makeController(
            currentStoreFormatVersion: 5,
            backupPolicy: .beforeSchemaUpgrade
        )

        let result = try controller.prepareStore(at: directory)

        guard case .ready(let plan) = result else {
            return XCTFail("Expected store preparation to succeed.")
        }
        XCTAssertEqual(plan.activeStoreFormatVersion, 5)
        XCTAssertTrue(plan.manifestWasCreated)
        XCTAssertNil(plan.createdBackup)
        XCTAssertNil(plan.restoredBackup)

        let manifest = try readManifest(from: directory)
        XCTAssertEqual(manifest.activeStoreFormatVersion, 5)
        XCTAssertTrue(manifest.backups.isEmpty)
    }

    func testMissingManifestWithExistingStoreUsesBundleBuildForV5LegacyStore() throws {
        let directory = try makeTemporaryStoreDirectory()
        try writeStoreFiles(in: directory, contents: "legacy")
        let controller = makeController(
            currentStoreFormatVersion: 6,
            backupPolicy: .beforeSchemaUpgrade,
            bundleBuildNumber: 585
        )

        let result = try controller.prepareStore(at: directory)

        guard case .ready(let plan) = result else {
            return XCTFail("Expected existing store without a manifest to prepare as a legacy store.")
        }
        XCTAssertEqual(plan.activeStoreFormatVersion, 5)
        XCTAssertTrue(plan.manifestWasCreated)
        let createdBackup = try XCTUnwrap(plan.createdBackup)
        XCTAssertEqual(createdBackup.storeFormatVersion, 5)
        XCTAssertEqual(createdBackup.createdBeforeUpgradingToStoreFormatVersion, 6)
        XCTAssertNil(plan.restoredBackup)

        let manifestBeforeOpen = try readManifest(from: directory)
        XCTAssertEqual(manifestBeforeOpen.activeStoreFormatVersion, 5)
        XCTAssertEqual(manifestBeforeOpen.backups.map(\.storeFormatVersion), [5])
        XCTAssertEqual(
            try readText(directory.appendingPathComponent(createdBackup.directoryName).appendingPathComponent("LocalStore.sqlite")),
            "legacy-main"
        )

        try controller.markStoreOpenedSuccessfully(plan, at: directory)

        let manifestAfterOpen = try readManifest(from: directory)
        XCTAssertEqual(manifestAfterOpen.activeStoreFormatVersion, 6)
        XCTAssertEqual(manifestAfterOpen.backups.map(\.storeFormatVersion), [5])
    }

    func testMissingManifestWithExistingStoreUsesBundleBuildForV3LegacyStore() throws {
        for buildNumber in [494, 584] {
            let directory = try makeTemporaryStoreDirectory()
            try writeStoreFiles(in: directory, contents: "legacy")
            let controller = makeController(
                currentStoreFormatVersion: 6,
                backupPolicy: .beforeSchemaUpgrade,
                bundleBuildNumber: buildNumber
            )

            let result = try controller.prepareStore(at: directory)

            guard case .ready(let plan) = result else {
                return XCTFail("Expected existing store without a manifest to prepare as a legacy store.")
            }
            XCTAssertEqual(plan.activeStoreFormatVersion, 3)
            let createdBackup = try XCTUnwrap(plan.createdBackup)
            XCTAssertEqual(createdBackup.storeFormatVersion, 3)
            XCTAssertEqual(createdBackup.createdBeforeUpgradingToStoreFormatVersion, 6)

            let manifestBeforeOpen = try readManifest(from: directory)
            XCTAssertEqual(manifestBeforeOpen.activeStoreFormatVersion, 3)
            XCTAssertEqual(manifestBeforeOpen.backups.map(\.storeFormatVersion), [3])
        }
    }

    func testMissingManifestWithExistingStoreTreatsUnmappedBundleBuildAsCurrentFormat() throws {
        let directory = try makeTemporaryStoreDirectory()
        try writeStoreFiles(in: directory, contents: "legacy")
        let controller = makeController(
            currentStoreFormatVersion: 6,
            backupPolicy: .beforeSchemaUpgrade,
            bundleBuildNumber: 493
        )

        let result = try controller.prepareStore(at: directory)

        guard case .ready(let plan) = result else {
            return XCTFail("Expected existing store without a manifest to prepare as the current format.")
        }
        XCTAssertEqual(plan.activeStoreFormatVersion, 6)
        XCTAssertTrue(plan.manifestWasCreated)
        XCTAssertNil(plan.createdBackup)

        let manifest = try readManifest(from: directory)
        XCTAssertEqual(manifest.activeStoreFormatVersion, 6)
        XCTAssertTrue(manifest.backups.isEmpty)
    }

    func testPrepareCreatesBackupWhenPolicyRequestsBackupBeforeSchemaUpgrade() throws {
        let directory = try makeTemporaryStoreDirectory()
        try writeStoreFiles(in: directory, contents: "v4")
        try writeManifest(
            LocalStoreCompatibilityManifest(activeStoreFormatVersion: 4, backups: []),
            to: directory
        )
        let controller = makeController(
            currentStoreFormatVersion: 5,
            backupPolicy: .init { context in
                context.activeStoreFormatVersion < context.currentStoreFormatVersion
            }
        )

        let result = try controller.prepareStore(at: directory)

        guard case .ready(let plan) = result else {
            return XCTFail("Expected store preparation to succeed.")
        }
        let createdBackup = try XCTUnwrap(plan.createdBackup)
        XCTAssertEqual(createdBackup.storeFormatVersion, 4)
        XCTAssertEqual(createdBackup.createdBeforeUpgradingToStoreFormatVersion, 5)
        XCTAssertNil(plan.restoredBackup)

        let manifestBeforeOpen = try readManifest(from: directory)
        XCTAssertEqual(manifestBeforeOpen.activeStoreFormatVersion, 4)
        XCTAssertEqual(manifestBeforeOpen.backups.map(\.storeFormatVersion), [4])
        XCTAssertEqual(
            try readText(directory.appendingPathComponent(createdBackup.directoryName).appendingPathComponent("LocalStore.sqlite")),
            "v4-main"
        )
        XCTAssertEqual(
            try readText(directory.appendingPathComponent(createdBackup.directoryName).appendingPathComponent("LocalStore.sqlite-wal")),
            "v4-wal"
        )
        XCTAssertEqual(
            try readText(directory.appendingPathComponent(createdBackup.directoryName).appendingPathComponent("LocalStore.sqlite-shm")),
            "v4-shm"
        )

        try controller.markStoreOpenedSuccessfully(plan, at: directory)

        let manifestAfterOpen = try readManifest(from: directory)
        XCTAssertEqual(manifestAfterOpen.activeStoreFormatVersion, 5)
        XCTAssertEqual(manifestAfterOpen.backups.map(\.storeFormatVersion), [4])
    }

    func testPrepareRestoresHighestReadableBackupWhenActiveStoreIsTooNew() throws {
        let directory = try makeTemporaryStoreDirectory()
        try writeStoreFiles(in: directory, contents: "v5")
        let v3Backup = try createBackup(in: directory, id: "v3-backup", storeFormatVersion: 3)
        let v4Backup = try createBackup(in: directory, id: "v4-backup", storeFormatVersion: 4)
        try writeManifest(
            LocalStoreCompatibilityManifest(activeStoreFormatVersion: 5, backups: [v3Backup, v4Backup]),
            to: directory
        )
        let controller = makeController(currentStoreFormatVersion: 4, readableStoreFormatVersions: 1...4)

        let result = try controller.prepareStore(at: directory)

        guard case .ready(let plan) = result else {
            return XCTFail("Expected a readable backup to be restored.")
        }
        XCTAssertEqual(plan.restoredBackup?.storeFormatVersion, 4)
        XCTAssertEqual(try readText(directory.appendingPathComponent("LocalStore.sqlite")), "v4-backup-main")
        XCTAssertEqual(try readText(directory.appendingPathComponent("LocalStore.sqlite-wal")), "v4-backup-wal")
        XCTAssertEqual(try readText(directory.appendingPathComponent("LocalStore.sqlite-shm")), "v4-backup-shm")

        let manifest = try readManifest(from: directory)
        XCTAssertEqual(manifest.activeStoreFormatVersion, 4)
        XCTAssertEqual(manifest.backups.map(\.storeFormatVersion), [3, 4])
    }

    func testRestoredBackupIsConsumedAfterStoreOpensSuccessfully() throws {
        let directory = try makeTemporaryStoreDirectory()
        try writeStoreFiles(in: directory, contents: "v5")
        let v3Backup = try createBackup(in: directory, id: "v3-backup", storeFormatVersion: 3)
        let v4Backup = try createBackup(in: directory, id: "v4-backup", storeFormatVersion: 4)
        try writeManifest(
            LocalStoreCompatibilityManifest(activeStoreFormatVersion: 5, backups: [v3Backup, v4Backup]),
            to: directory
        )
        let controller = makeController(currentStoreFormatVersion: 4, readableStoreFormatVersions: 1...4)

        let result = try controller.prepareStore(at: directory)

        guard case .ready(let plan) = result else {
            return XCTFail("Expected a readable backup to be restored.")
        }
        let restoredBackup = try XCTUnwrap(plan.restoredBackup)
        let restoredBackupDirectory = directory.appendingPathComponent(restoredBackup.directoryName, isDirectory: true)
        XCTAssertEqual(restoredBackup.id, "v4-backup")
        XCTAssertTrue(FileManager.default.fileExists(atPath: restoredBackupDirectory.path))
        XCTAssertEqual(try readManifest(from: directory).backups.map(\.id), ["v3-backup", "v4-backup"])

        try controller.markStoreOpenedSuccessfully(plan, at: directory)

        let manifestAfterOpen = try readManifest(from: directory)
        XCTAssertEqual(manifestAfterOpen.activeStoreFormatVersion, 4)
        XCTAssertEqual(manifestAfterOpen.backups.map(\.id), ["v3-backup"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: restoredBackupDirectory.path))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(v3Backup.directoryName, isDirectory: true).path
            )
        )
    }

    func testPrepareRestoresLowerReadableBackupWhenExactVersionIsUnavailable() throws {
        let directory = try makeTemporaryStoreDirectory()
        try writeStoreFiles(in: directory, contents: "v5")
        let v3Backup = try createBackup(in: directory, id: "v3-backup", storeFormatVersion: 3)
        try writeManifest(
            LocalStoreCompatibilityManifest(activeStoreFormatVersion: 5, backups: [v3Backup]),
            to: directory
        )
        let controller = makeController(currentStoreFormatVersion: 4, readableStoreFormatVersions: 1...4)

        let result = try controller.prepareStore(at: directory)

        guard case .ready(let plan) = result else {
            return XCTFail("Expected the lower readable backup to be restored.")
        }
        XCTAssertEqual(plan.restoredBackup?.storeFormatVersion, 3)
        XCTAssertEqual(try readText(directory.appendingPathComponent("LocalStore.sqlite")), "v3-backup-main")
    }

    func testPrepareRequiresNewerAppWhenNoReadableBackupExists() throws {
        let directory = try makeTemporaryStoreDirectory()
        try writeStoreFiles(in: directory, contents: "v5")
        try writeManifest(
            LocalStoreCompatibilityManifest(activeStoreFormatVersion: 5, backups: []),
            to: directory
        )
        let controller = makeController(currentStoreFormatVersion: 4, readableStoreFormatVersions: 1...4)

        let result = try controller.prepareStore(at: directory)

        guard case .requiresNewerApp(let issue) = result else {
            return XCTFail("Expected the active store to require a newer app.")
        }
        XCTAssertEqual(issue.activeStoreFormatVersion, 5)
        XCTAssertEqual(issue.currentStoreFormatVersion, 4)
    }

    func testLocalStoreDoesNotCreateContainerWhenActiveStoreRequiresNewerApp() throws {
        let directory = try makeTemporaryStoreDirectory()
        try writeManifest(
            LocalStoreCompatibilityManifest(activeStoreFormatVersion: 99, backups: []),
            to: directory
        )

        let store = LocalStore(
            account: Account(userID: UUID().uuidString),
            storeDirectoryURL: directory,
            presentsCompatibilityAlerts: false
        )

        XCTAssertNil(store.getMainContext())
        guard case .requiresNewerApp(let issue) = store.compatibilityStatus else {
            return XCTFail("Expected LocalStore to stop before creating the model container.")
        }
        XCTAssertEqual(issue.activeStoreFormatVersion, 99)
    }

    func testSwiftDataStoreBackupRestoresReadableStoreForOlderSchema() throws {
        let directory = try makeTemporaryStoreDirectory()
        let storeURL = directory.appendingPathComponent("LocalStore.sqlite")
        try createVersionOneSwiftDataStore(at: storeURL)
        try writeManifest(
            LocalStoreCompatibilityManifest(activeStoreFormatVersion: 1, backups: []),
            to: directory
        )

        let upgradeController = makeController(
            currentStoreFormatVersion: 2,
            readableStoreFormatVersions: 1...2,
            backupPolicy: .beforeSchemaUpgrade
        )

        let upgradeResult = try upgradeController.prepareStore(at: directory)

        guard case .ready(let upgradePlan) = upgradeResult else {
            return XCTFail("Expected version two to prepare the version one store.")
        }
        let createdBackup = try XCTUnwrap(upgradePlan.createdBackup)
        XCTAssertEqual(createdBackup.storeFormatVersion, 1)

        try openAndMigrateStoreToVersionTwo(at: storeURL)
        try upgradeController.markStoreOpenedSuccessfully(upgradePlan, at: directory)
        XCTAssertEqual(try readManifest(from: directory).activeStoreFormatVersion, 2)

        let downgradeController = makeController(
            currentStoreFormatVersion: 1,
            readableStoreFormatVersions: 1...1
        )

        let downgradeResult = try downgradeController.prepareStore(at: directory)

        guard case .ready(let downgradePlan) = downgradeResult else {
            return XCTFail("Expected version one to restore a readable backup.")
        }
        XCTAssertEqual(downgradePlan.restoredBackup?.storeFormatVersion, 1)

        let restoredItem = try fetchVersionOneItem(at: storeURL)
        XCTAssertEqual(restoredItem.id, "item-1")
        XCTAssertEqual(restoredItem.title, "Created by v1")
        let restoredBackupDirectory = try XCTUnwrap(downgradePlan.restoredBackup?.directoryName)
        try downgradeController.markStoreOpenedSuccessfully(downgradePlan, at: directory)
        XCTAssertEqual(try readManifest(from: directory).activeStoreFormatVersion, 1)
        XCTAssertTrue(try readManifest(from: directory).backups.isEmpty)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(restoredBackupDirectory, isDirectory: true).path
            )
        )
    }

    // CASE 2a.24 / C-3 —— schema V11 的升级按 Compatibility/README.md 规则 3 走
    // `beforeSchemaUpgrade`：写一次 manifest、造一次备份，第二次打开不再造第二份。
    func testUpgradeToStoreFormatElevenCreatesManifestAndBackupExactlyOnce() throws {
        let directory = try makeTemporaryStoreDirectory()
        try writeStoreFiles(in: directory, contents: "v10")
        try writeManifest(
            LocalStoreCompatibilityManifest(activeStoreFormatVersion: 10, backups: []),
            to: directory
        )
        let controller = makeController(
            currentStoreFormatVersion: 11,
            readableStoreFormatVersions: 1...11,
            backupPolicy: .beforeSchemaUpgrade
        )

        let result = try controller.prepareStore(at: directory)

        guard case .ready(let plan) = result else {
            return XCTFail("Expected the version ten store to prepare for a version eleven app.")
        }
        let createdBackup = try XCTUnwrap(plan.createdBackup)
        XCTAssertEqual(createdBackup.storeFormatVersion, 10)
        XCTAssertEqual(createdBackup.createdBeforeUpgradingToStoreFormatVersion, 11)
        XCTAssertNil(plan.restoredBackup)
        XCTAssertEqual(
            try readText(directory.appendingPathComponent(createdBackup.directoryName).appendingPathComponent("LocalStore.sqlite")),
            "v10-main"
        )

        try controller.markStoreOpenedSuccessfully(plan, at: directory)

        let manifestAfterOpen = try readManifest(from: directory)
        XCTAssertEqual(manifestAfterOpen.activeStoreFormatVersion, 11)
        XCTAssertEqual(manifestAfterOpen.backups.map(\.storeFormatVersion), [10])

        let secondResult = try controller.prepareStore(at: directory)

        guard case .ready(let secondPlan) = secondResult else {
            return XCTFail("Expected the already-upgraded store to prepare without a backup.")
        }
        XCTAssertNil(secondPlan.createdBackup)
        XCTAssertEqual(try readManifest(from: directory).backups.map(\.storeFormatVersion), [10])
    }

    // CASE 2a.25 —— `readableStoreFormatVersions` 的上下界。
    func testShippingReadableStoreFormatVersionBounds() throws {
        // 这两处断言的是出厂配置本身，留字面量：它们是整条链的锚点。
        XCTAssertEqual(LocalStore.compatibilityConfiguration.currentStoreFormatVersion, 11)
        XCTAssertEqual(LocalStore.compatibilityConfiguration.readableStoreFormatVersions, 1...11)

        let controller = makeController(
            currentStoreFormatVersion: 11,
            readableStoreFormatVersions: 1...11
        )

        // 「太新」那一组从出厂配置派生（`current + 1`），下一次版本提升不必再改这里。
        let tooNewVersion = LocalStore.compatibilityConfiguration.currentStoreFormatVersion + 1
        let tooNewDirectory = try makeTemporaryStoreDirectory()
        try writeStoreFiles(in: tooNewDirectory, contents: "v\(tooNewVersion)")
        try writeManifest(
            LocalStoreCompatibilityManifest(activeStoreFormatVersion: tooNewVersion, backups: []),
            to: tooNewDirectory
        )

        guard case .requiresNewerApp(let issue) = try controller.prepareStore(at: tooNewDirectory) else {
            return XCTFail("Expected a store format above the readable range to require a newer app.")
        }
        XCTAssertEqual(issue.activeStoreFormatVersion, tooNewVersion)
        XCTAssertEqual(issue.currentStoreFormatVersion, 11)

        let oldestDirectory = try makeTemporaryStoreDirectory()
        try writeStoreFiles(in: oldestDirectory, contents: "v1")
        try writeManifest(
            LocalStoreCompatibilityManifest(activeStoreFormatVersion: 1, backups: []),
            to: oldestDirectory
        )

        guard case .ready(let plan) = try controller.prepareStore(at: oldestDirectory) else {
            return XCTFail("Expected the lower bound of the readable range to open.")
        }
        XCTAssertEqual(plan.activeStoreFormatVersion, 1)
    }

    // CASE 2a.25b / C-4 —— 降级路径：V11 的库被一个只认到 V10 的构建打开。用户在两个构建之间
    // 来回切时，一次「打开即降级」会把 V11 写下的六列丢掉——那等于全库规则行的账户身份、软删
    // 意图、合并伙伴同时消失：下一次再跑新构建时，差分把整张 `urlrules-cursors.json` 判成本机
    // 删除，一轮之内给账户上每一条规则发出 tombstone。所以按 README 规则 4 的降级语义：拒绝
    // 打开并保留那份库，不就地降级、不删除。
    func testStoreFormatElevenIsPreservedWhenOpenedByAnAppThatOnlyReadsTen() throws {
        let directory = try makeTemporaryStoreDirectory()
        try writeStoreFiles(in: directory, contents: "v11")
        try writeManifest(
            LocalStoreCompatibilityManifest(activeStoreFormatVersion: 11, backups: []),
            to: directory
        )
        // 「降级构建」那一组从出厂配置派生（`current - 1`）。
        let olderBuildVersion = LocalStore.compatibilityConfiguration.currentStoreFormatVersion - 1
        let olderBuildController = makeController(
            currentStoreFormatVersion: olderBuildVersion,
            readableStoreFormatVersions: 1...olderBuildVersion,
            backupPolicy: .beforeSchemaUpgrade
        )

        let result = try olderBuildController.prepareStore(at: directory)

        guard case .requiresNewerApp(let issue) = result else {
            return XCTFail("Expected a version eleven store to be refused by a version ten app.")
        }
        XCTAssertEqual(issue.activeStoreFormatVersion, 11)
        XCTAssertEqual(issue.currentStoreFormatVersion, olderBuildVersion)

        XCTAssertEqual(try readText(directory.appendingPathComponent("LocalStore.sqlite")), "v11-main")
        XCTAssertEqual(try readText(directory.appendingPathComponent("LocalStore.sqlite-wal")), "v11-wal")
        XCTAssertEqual(try readText(directory.appendingPathComponent("LocalStore.sqlite-shm")), "v11-shm")
        let manifest = try readManifest(from: directory)
        XCTAssertEqual(manifest.activeStoreFormatVersion, 11)
        XCTAssertTrue(manifest.backups.isEmpty)
    }

    private func makeController(
        currentStoreFormatVersion: Int,
        readableStoreFormatVersions: ClosedRange<Int>? = nil,
        backupPolicy: LocalStoreBackupPolicy = .never,
        bundleBuildNumber: Int? = nil
    ) -> LocalStoreCompatibilityController {
        LocalStoreCompatibilityController(
            configuration: LocalStoreCompatibilityConfiguration(
                currentStoreFormatVersion: currentStoreFormatVersion,
                readableStoreFormatVersions: readableStoreFormatVersions ?? 1...currentStoreFormatVersion,
                storeFilename: "LocalStore.sqlite",
                manifestFilename: "LocalStoreCompatibility.json",
                backupsDirectoryName: "Backups",
                backupPolicy: backupPolicy,
                dateProvider: { Date(timeIntervalSince1970: 1_800_000_000) },
                idProvider: { "backup-id" },
                bundleBuildNumberProvider: { bundleBuildNumber }
            )
        )
    }

    private func makeTemporaryStoreDirectory() throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectories.append(directory)
        return directory
    }

    private func writeStoreFiles(in directory: URL, contents: String) throws {
        try writeText("\(contents)-main", to: directory.appendingPathComponent("LocalStore.sqlite"))
        try writeText("\(contents)-wal", to: directory.appendingPathComponent("LocalStore.sqlite-wal"))
        try writeText("\(contents)-shm", to: directory.appendingPathComponent("LocalStore.sqlite-shm"))
    }

    private func createBackup(in directory: URL, id: String, storeFormatVersion: Int) throws -> LocalStoreBackupRecord {
        let relativeDirectory = "Backups/\(id)"
        let backupDirectory = directory.appendingPathComponent(relativeDirectory, isDirectory: true)
        try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        try writeText("v\(storeFormatVersion)-backup-main", to: backupDirectory.appendingPathComponent("LocalStore.sqlite"))
        try writeText("v\(storeFormatVersion)-backup-wal", to: backupDirectory.appendingPathComponent("LocalStore.sqlite-wal"))
        try writeText("v\(storeFormatVersion)-backup-shm", to: backupDirectory.appendingPathComponent("LocalStore.sqlite-shm"))
        return LocalStoreBackupRecord(
            id: id,
            storeFormatVersion: storeFormatVersion,
            directoryName: relativeDirectory,
            createdAt: Date(timeIntervalSince1970: TimeInterval(storeFormatVersion)),
            createdBeforeUpgradingToStoreFormatVersion: storeFormatVersion + 1
        )
    }

    private func writeManifest(_ manifest: LocalStoreCompatibilityManifest, to directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        try data.write(to: directory.appendingPathComponent("LocalStoreCompatibility.json"))
    }

    private func readManifest(from directory: URL) throws -> LocalStoreCompatibilityManifest {
        let data = try Data(contentsOf: directory.appendingPathComponent("LocalStoreCompatibility.json"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(LocalStoreCompatibilityManifest.self, from: data)
    }

    private func writeText(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.data(using: .utf8)?.write(to: url)
    }

    private func readText(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return String(decoding: data, as: UTF8.self)
    }

    private func createVersionOneSwiftDataStore(at url: URL) throws {
        let configuration = ModelConfiguration(url: url)
        let container = try ModelContainer(
            for: CompatibilityTestSchemaV1.Item.self,
            configurations: configuration
        )
        let context = container.mainContext
        context.insert(CompatibilityTestSchemaV1.Item(id: "item-1", title: "Created by v1"))
        try context.save()
    }

    private func openAndMigrateStoreToVersionTwo(at url: URL) throws {
        let configuration = ModelConfiguration(url: url)
        let container = try ModelContainer(
            for: CompatibilityTestSchemaV2.Item.self,
            migrationPlan: CompatibilityTestMigrationPlan.self,
            configurations: configuration
        )
        let context = container.mainContext
        let items = try context.fetch(FetchDescriptor<CompatibilityTestSchemaV2.Item>())
        let item = try XCTUnwrap(items.first)
        item.subtitle = "Written by v2"
        try context.save()
    }

    private func fetchVersionOneItem(at url: URL) throws -> (id: String, title: String) {
        let configuration = ModelConfiguration(url: url)
        let container = try ModelContainer(
            for: CompatibilityTestSchemaV1.Item.self,
            configurations: configuration
        )
        let context = container.mainContext
        let items = try context.fetch(FetchDescriptor<CompatibilityTestSchemaV1.Item>())
        let item = try XCTUnwrap(items.first)
        return (item.id, item.title)
    }
}

private enum CompatibilityTestMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [CompatibilityTestSchemaV1.self, CompatibilityTestSchemaV2.self]
    }

    static var stages: [MigrationStage] {
        [
            MigrationStage.lightweight(
                fromVersion: CompatibilityTestSchemaV1.self,
                toVersion: CompatibilityTestSchemaV2.self
            ),
        ]
    }
}

private enum CompatibilityTestSchemaV1: VersionedSchema {
    static var versionIdentifier = Schema.Version(1, 0, 0)

    static var models: [any PersistentModel.Type] {
        [Item.self]
    }

    @Model
    final class Item {
        var id: String
        var title: String

        init(id: String, title: String) {
            self.id = id
            self.title = title
        }
    }
}

private enum CompatibilityTestSchemaV2: VersionedSchema {
    static var versionIdentifier = Schema.Version(2, 0, 0)

    static var models: [any PersistentModel.Type] {
        [Item.self]
    }

    @Model
    final class Item {
        var id: String
        var title: String
        var subtitle: String?

        init(id: String, title: String, subtitle: String? = nil) {
            self.id = id
            self.title = title
            self.subtitle = subtitle
        }
    }
}

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
        let controller = makeController(currentStoreFormatVersion: 5)

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

    private func makeController(
        currentStoreFormatVersion: Int,
        readableStoreFormatVersions: ClosedRange<Int>? = nil,
        backupPolicy: LocalStoreBackupPolicy = .never
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
                idProvider: { "backup-id" }
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

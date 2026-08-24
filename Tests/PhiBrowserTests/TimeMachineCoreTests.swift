// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

final class TimeMachineCoreTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
    }

    func testReleasePolicyMatchesOnlyExactTriggerVersion() throws {
        let policy = TimeMachineRollbackPolicy(
            backupTriggerBuild: 600,
            backupTriggerVersion: "2.0",
            rollbackVersion: "1.6.0",
            rollbackBuild: 590,
            rollbackPackageURL: try XCTUnwrap(URL(string: "https://example.com/Phi-1.6-590.zip")),
            rollbackPackageSHA256: "abc123",
            includeChromiumData: true
        )

        XCTAssertTrue(policy.shouldCreateBackup(currentVersion: "2.0", currentBuild: 601, triggerMode: .version))
        XCTAssertFalse(policy.shouldCreateBackup(currentVersion: "1.9", currentBuild: 600, triggerMode: .version))
        XCTAssertFalse(policy.shouldCreateBackup(currentVersion: "2.0.1", currentBuild: 600, triggerMode: .version))
    }

    func testNightlyPolicyMatchesOnlyExactTriggerBuild() throws {
        let policy = TimeMachineRollbackPolicy(
            backupTriggerBuild: 600,
            backupTriggerVersion: "2.0",
            rollbackVersion: "1.6.0",
            rollbackBuild: 590,
            rollbackPackageURL: try XCTUnwrap(URL(string: "https://example.com/Phi-1.6-590.zip")),
            rollbackPackageSHA256: "abc123",
            includeChromiumData: true
        )

        XCTAssertTrue(policy.shouldCreateBackup(currentVersion: "2.1", currentBuild: 600, triggerMode: .build))
        XCTAssertFalse(policy.shouldCreateBackup(currentVersion: "2.0", currentBuild: 599, triggerMode: .build))
        XCTAssertFalse(policy.shouldCreateBackup(currentVersion: "2.0", currentBuild: 601, triggerMode: .build))
    }

    func testDefaultRootURLIsScopedByBundleIdentifier() throws {
        let rootURL = TimeMachinePaths.defaultRootURL(bundleIdentifier: "com.phibrowser.canary.Mac")

        XCTAssertEqual(rootURL.lastPathComponent, "com.phibrowser.canary.Mac")
        XCTAssertEqual(rootURL.deletingLastPathComponent().lastPathComponent, TimeMachinePaths.defaultRootDirectoryName)
    }

    func testCatalogStoresCompletedBackupsAndRendersMenuLabel() throws {
        let root = try makeTemporaryDirectory()
        let paths = TimeMachinePaths(rootURL: root, bundleIdentifier: "com.phibrowser.Mac")
        let store = TimeMachineCatalogStore(paths: paths)
        let createdAt = try XCTUnwrap(DateComponents(
            calendar: Calendar(identifier: .gregorian),
            timeZone: TimeZone(secondsFromGMT: 0),
            year: 2026,
            month: 6,
            day: 11,
            hour: 9
        ).date)
        let record = TimeMachineBackupRecord(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000600")!,
            createdAt: createdAt,
            creatingVersion: "2.0",
            creatingBuild: 600,
            backupTriggerBuild: 600,
            rollbackVersion: "1.6.0",
            rollbackBuild: 590,
            rollbackPackageURL: try XCTUnwrap(URL(string: "https://example.com/Phi-1.6-590.zip")),
            rollbackPackageSHA256: "abc123",
            includeChromiumData: true,
            snapshotRelativePath: "Snapshots/00000000-0000-0000-0000-000000000600",
            status: .completed
        )

        try store.save(TimeMachineCatalog(backups: [record]))

        let loaded = try store.load()
        XCTAssertEqual(loaded.completedBackups, [record])
        XCTAssertEqual(loaded.completedBackups.first?.menuTitle(timeZone: TimeZone(secondsFromGMT: 0)!), "Phi 1.6.0 (590) on 2026.6.11")
        XCTAssertTrue(loaded.hasCompletedBackup(triggerBuild: 600))
        XCTAssertFalse(loaded.hasCompletedBackup(triggerBuild: 601))
        XCTAssertTrue(loaded.hasCompletedBackup(creatingVersion: "2.0"))
        XCTAssertFalse(loaded.hasCompletedBackup(creatingVersion: "2.0.1"))
    }

    func testCatalogStoreDeletesSnapshotAndRecordTogether() throws {
        let root = try makeTemporaryDirectory()
        let paths = TimeMachinePaths(rootURL: root, bundleIdentifier: "com.phibrowser.Mac")
        let store = TimeMachineCatalogStore(paths: paths)
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000601")!
        let snapshotURL = paths.snapshotURL(id: id)
        try FileManager.default.createDirectory(at: snapshotURL, withIntermediateDirectories: true)
        try Data(repeating: 0x1, count: 512).write(to: snapshotURL.appendingPathComponent("data.bin"))
        let record = try makeBackupRecord(id: id, snapshotRelativePath: paths.relativePath(for: snapshotURL))
        try store.save(TimeMachineCatalog(backups: [record]))

        let deleted = try store.deleteBackup(id: id)

        XCTAssertEqual(deleted, record)
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshotURL.path))
        XCTAssertTrue(try store.load().backups.isEmpty)
    }

    func testUserRequestedDeletionRetainsTriggerMarker() throws {
        let root = try makeTemporaryDirectory()
        let paths = TimeMachinePaths(rootURL: root, bundleIdentifier: "com.phibrowser.Mac")
        let store = TimeMachineCatalogStore(paths: paths)
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000614")!
        let snapshotURL = paths.snapshotURL(id: id)
        try FileManager.default.createDirectory(at: snapshotURL, withIntermediateDirectories: true)
        let record = try makeBackupRecord(id: id, snapshotRelativePath: paths.relativePath(for: snapshotURL))
        try store.save(TimeMachineCatalog(backups: [record]))

        XCTAssertEqual(try store.deleteBackupAtUserRequest(id: id), record)

        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshotURL.path))
        let catalog = try store.load()
        XCTAssertTrue(catalog.completedBackups.isEmpty)
        XCTAssertTrue(catalog.backups.isEmpty)
        XCTAssertEqual(
            catalog.suppressedBackupTriggers,
            [TimeMachineSuppressedBackupTrigger(
                backupTriggerBuild: record.backupTriggerBuild,
                creatingVersion: record.creatingVersion
            )]
        )
        XCTAssertTrue(catalog.hasHandledBackup(triggerBuild: record.backupTriggerBuild))
        XCTAssertTrue(catalog.hasHandledBackup(creatingVersion: record.creatingVersion))

        let data = try Data(contentsOf: paths.catalogURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertTrue(try decoder.decode(LegacyTimeMachineCatalog.self, from: data).backups.isEmpty)
    }

    func testSnapshotSizeUpdateDoesNotReinsertDeletedBackup() throws {
        let root = try makeTemporaryDirectory()
        let paths = TimeMachinePaths(rootURL: root, bundleIdentifier: "com.phibrowser.Mac")
        let store = TimeMachineCatalogStore(paths: paths)
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000618")!
        let snapshotURL = paths.snapshotURL(id: id)
        try FileManager.default.createDirectory(at: snapshotURL, withIntermediateDirectories: true)
        let record = try makeBackupRecord(id: id, snapshotRelativePath: paths.relativePath(for: snapshotURL))
        try store.save(TimeMachineCatalog(backups: [record]))
        _ = try store.deleteBackupAtUserRequest(id: id)

        XCTAssertNil(try store.updateSnapshotSizeBytes(id: id, sizeBytes: 1_024))

        let catalog = try store.load()
        XCTAssertTrue(catalog.backups.isEmpty)
        XCTAssertEqual(catalog.suppressedBackupTriggers.count, 1)
    }

    func testCatalogStoreRejectsBackupDeletionOutsideSnapshotsRoot() throws {
        let root = try makeTemporaryDirectory()
        let paths = TimeMachinePaths(rootURL: root.appendingPathComponent("TimeMachine"), bundleIdentifier: "com.phibrowser.Mac")
        let store = TimeMachineCatalogStore(paths: paths)
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000602")!
        let externalURL = root.appendingPathComponent("external.txt")
        try "keep".write(to: externalURL, atomically: true, encoding: .utf8)
        let record = try makeBackupRecord(id: id, snapshotRelativePath: externalURL.path)
        try store.save(TimeMachineCatalog(backups: [record]))

        XCTAssertThrowsError(try store.deleteBackup(id: id)) { error in
            guard case TimeMachineCatalogStoreError.invalidSnapshotPath = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: externalURL.path))
        XCTAssertEqual(try store.load().backups, [record])
    }

    func testCatalogStoreRejectsNonCanonicalSnapshotPaths() throws {
        let root = try makeTemporaryDirectory()
        let paths = TimeMachinePaths(rootURL: root, bundleIdentifier: "com.phibrowser.Mac")
        let store = TimeMachineCatalogStore(paths: paths)
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000611")!
        let nonCanonicalPaths = [
            "Snapshots/child/../\(id.uuidString)",
            "Snapshots//\(id.uuidString)",
            "Snapshots/./\(id.uuidString)"
        ]

        for snapshotRelativePath in nonCanonicalPaths {
            let record = try makeBackupRecord(id: id, snapshotRelativePath: snapshotRelativePath)
            try store.save(TimeMachineCatalog(backups: [record]))

            XCTAssertThrowsError(try store.deleteBackup(id: id)) { error in
                guard case TimeMachineCatalogStoreError.invalidSnapshotPath = error else {
                    return XCTFail("Unexpected error for \(snapshotRelativePath): \(error)")
                }
            }
            XCTAssertEqual(try store.load().backups, [record])
        }
    }

    func testCatalogStoreRemovesRecordWhenSnapshotIsAlreadyMissing() throws {
        let root = try makeTemporaryDirectory()
        let paths = TimeMachinePaths(rootURL: root, bundleIdentifier: "com.phibrowser.Mac")
        let store = TimeMachineCatalogStore(paths: paths)
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000603")!
        let record = try makeBackupRecord(
            id: id,
            snapshotRelativePath: paths.relativePath(for: paths.snapshotURL(id: id))
        )
        try store.save(TimeMachineCatalog(backups: [record]))

        XCTAssertEqual(try store.deleteBackup(id: id), record)
        XCTAssertTrue(try store.load().backups.isEmpty)
    }

    func testCatalogStoreRejectsSymlinkedSnapshotsDirectoryWithoutDeletingExternalData() throws {
        let root = try makeTemporaryDirectory()
        let paths = TimeMachinePaths(
            rootURL: root.appendingPathComponent("TimeMachine", isDirectory: true),
            bundleIdentifier: "com.phibrowser.Mac"
        )
        let externalSnapshotsURL = root.appendingPathComponent("ExternalSnapshots", isDirectory: true)
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000604")!
        let externalSnapshotURL = externalSnapshotsURL.appendingPathComponent(id.uuidString, isDirectory: true)
        let markerURL = externalSnapshotURL.appendingPathComponent("keep.txt")
        try FileManager.default.createDirectory(at: externalSnapshotURL, withIntermediateDirectories: true)
        try "keep".write(to: markerURL, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: paths.snapshotsRootURL, withIntermediateDirectories: true)
        let record = try makeBackupRecord(
            id: id,
            snapshotRelativePath: "Snapshots/\(id.uuidString)"
        )
        let store = TimeMachineCatalogStore(paths: paths)
        try store.save(TimeMachineCatalog(backups: [record]))
        try FileManager.default.removeItem(at: paths.snapshotsRootURL)
        try FileManager.default.createSymbolicLink(
            at: paths.snapshotsRootURL,
            withDestinationURL: externalSnapshotsURL
        )

        XCTAssertThrowsError(try store.deleteBackup(id: id)) { error in
            guard case TimeMachineCatalogStoreError.unsafeManagedDirectory = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: markerURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.snapshotsRootURL.path))

        try FileManager.default.removeItem(at: paths.snapshotsRootURL)
        XCTAssertEqual(try store.load().backups, [record])
    }

    func testCatalogStoreRejectsSymlinkedManagedParentWithoutDeletingExternalData() throws {
        let root = try makeTemporaryDirectory()
        let managedParentURL = root.appendingPathComponent("ManagedParent", isDirectory: true)
        let externalParentURL = root.appendingPathComponent("ExternalParent", isDirectory: true)
        let paths = TimeMachinePaths(
            rootURL: managedParentURL.appendingPathComponent("TimeMachine", isDirectory: true),
            bundleIdentifier: "com.phibrowser.Mac"
        )
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000615")!
        let managedSnapshotURL = paths.snapshotURL(id: id)
        try FileManager.default.createDirectory(at: managedSnapshotURL, withIntermediateDirectories: true)
        try "keep".write(
            to: managedSnapshotURL.appendingPathComponent("keep.txt"),
            atomically: true,
            encoding: .utf8
        )
        let record = try makeBackupRecord(
            id: id,
            snapshotRelativePath: "Snapshots/\(id.uuidString)"
        )
        let store = TimeMachineCatalogStore(paths: paths)
        try store.save(TimeMachineCatalog(backups: [record]))
        try FileManager.default.moveItem(at: managedParentURL, to: externalParentURL)
        try FileManager.default.createSymbolicLink(at: managedParentURL, withDestinationURL: externalParentURL)
        let markerURL = externalParentURL
            .appendingPathComponent("TimeMachine/Snapshots", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
            .appendingPathComponent("keep.txt")

        XCTAssertThrowsError(try store.deleteBackup(id: id)) { error in
            guard case TimeMachineCatalogStoreError.unsafeManagedDirectory = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: markerURL.path))
    }

    func testCatalogStoreDeletesSnapshotSymlinkWithoutFollowingIt() throws {
        let root = try makeTemporaryDirectory()
        let paths = TimeMachinePaths(rootURL: root, bundleIdentifier: "com.phibrowser.Mac")
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000605")!
        let externalURL = root.appendingPathComponent("External", isDirectory: true)
        let markerURL = externalURL.appendingPathComponent("keep.txt")
        try FileManager.default.createDirectory(at: paths.snapshotsRootURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: externalURL, withIntermediateDirectories: true)
        try "keep".write(to: markerURL, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: paths.snapshotURL(id: id),
            withDestinationURL: externalURL
        )
        let record = try makeBackupRecord(
            id: id,
            snapshotRelativePath: paths.relativePath(for: paths.snapshotURL(id: id))
        )
        let store = TimeMachineCatalogStore(paths: paths)
        try store.save(TimeMachineCatalog(backups: [record]))

        XCTAssertEqual(try store.deleteBackup(id: id), record)

        XCTAssertTrue(FileManager.default.fileExists(atPath: markerURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.snapshotURL(id: id).path))
        XCTAssertTrue(try store.load().backups.isEmpty)
    }

    func testCatalogStoreDoesNotFollowSymlinksInsideSnapshot() throws {
        let root = try makeTemporaryDirectory()
        let paths = TimeMachinePaths(rootURL: root, bundleIdentifier: "com.phibrowser.Mac")
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000606")!
        let snapshotURL = paths.snapshotURL(id: id)
        let externalURL = root.appendingPathComponent("External", isDirectory: true)
        let markerURL = externalURL.appendingPathComponent("keep.txt")
        try FileManager.default.createDirectory(at: snapshotURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: externalURL, withIntermediateDirectories: true)
        try "keep".write(to: markerURL, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: snapshotURL.appendingPathComponent("external-link"),
            withDestinationURL: externalURL
        )
        try FileManager.default.createSymbolicLink(
            atPath: snapshotURL.appendingPathComponent("dangling-link").path,
            withDestinationPath: root.appendingPathComponent("missing").path
        )
        let record = try makeBackupRecord(
            id: id,
            snapshotRelativePath: paths.relativePath(for: snapshotURL)
        )
        let store = TimeMachineCatalogStore(paths: paths)
        try store.save(TimeMachineCatalog(backups: [record]))

        XCTAssertEqual(try store.deleteBackup(id: id), record)

        XCTAssertTrue(FileManager.default.fileExists(atPath: markerURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshotURL.path))
        XCTAssertTrue(try store.load().backups.isEmpty)
    }

    func testCatalogStoreSafelyDeletesUncatalogedSnapshotWithoutFollowingSymlinks() throws {
        let root = try makeTemporaryDirectory()
        let paths = TimeMachinePaths(rootURL: root, bundleIdentifier: "com.phibrowser.Mac")
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000612")!
        let snapshotURL = paths.snapshotURL(id: id)
        let externalURL = root.appendingPathComponent("External", isDirectory: true)
        let markerURL = externalURL.appendingPathComponent("keep.txt")
        try FileManager.default.createDirectory(at: snapshotURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: externalURL, withIntermediateDirectories: true)
        try "keep".write(to: markerURL, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: snapshotURL.appendingPathComponent("external-link"),
            withDestinationURL: externalURL
        )
        let store = TimeMachineCatalogStore(paths: paths)

        XCTAssertTrue(try store.deleteUncatalogedSnapshotIfExists(id: id))

        XCTAssertTrue(FileManager.default.fileExists(atPath: markerURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshotURL.path))
    }

    func testCatalogStoreRefusesUncatalogedDeletionForCatalogedSnapshot() throws {
        let root = try makeTemporaryDirectory()
        let paths = TimeMachinePaths(rootURL: root, bundleIdentifier: "com.phibrowser.Mac")
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000613")!
        let snapshotURL = paths.snapshotURL(id: id)
        try FileManager.default.createDirectory(at: snapshotURL, withIntermediateDirectories: true)
        let record = try makeBackupRecord(
            id: id,
            snapshotRelativePath: paths.relativePath(for: snapshotURL)
        )
        let store = TimeMachineCatalogStore(paths: paths)
        try store.save(TimeMachineCatalog(backups: [record]))

        XCTAssertThrowsError(try store.deleteUncatalogedSnapshotIfExists(id: id)) { error in
            guard case TimeMachineCatalogStoreError.snapshotStillCataloged = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshotURL.path))
        XCTAssertEqual(try store.load().backups, [record])
    }

    func testCatalogStoreRollsBackQuarantineWhenCatalogSaveFails() throws {
        let root = try makeTemporaryDirectory()
        let paths = TimeMachinePaths(rootURL: root, bundleIdentifier: "com.phibrowser.Mac")
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000607")!
        let snapshotURL = paths.snapshotURL(id: id)
        try FileManager.default.createDirectory(at: snapshotURL, withIntermediateDirectories: true)
        let record = try makeBackupRecord(
            id: id,
            snapshotRelativePath: paths.relativePath(for: snapshotURL)
        )
        let normalStore = TimeMachineCatalogStore(paths: paths)
        try normalStore.save(TimeMachineCatalog(backups: [record]))
        let failingStore = TimeMachineCatalogStore(
            paths: paths,
            catalogWriter: { _, _ in throw TimeMachineCatalogStoreTestError.writeFailed }
        )

        XCTAssertThrowsError(try failingStore.deleteBackup(id: id))

        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshotURL.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: paths.snapshotsRootURL.appendingPathComponent("\(id.uuidString).deleting").path
        ))
        XCTAssertEqual(try normalStore.load().backups, [record])
    }

    func testCatalogStoreRecoversUncommittedDeletionTombstone() throws {
        let root = try makeTemporaryDirectory()
        let paths = TimeMachinePaths(rootURL: root, bundleIdentifier: "com.phibrowser.Mac")
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000608")!
        let snapshotURL = paths.snapshotURL(id: id)
        let deletionURL = paths.snapshotsRootURL.appendingPathComponent("\(id.uuidString).deleting")
        try FileManager.default.createDirectory(at: snapshotURL, withIntermediateDirectories: true)
        let record = try makeBackupRecord(
            id: id,
            snapshotRelativePath: paths.relativePath(for: snapshotURL)
        )
        let store = TimeMachineCatalogStore(paths: paths)
        try store.save(TimeMachineCatalog(backups: [record]))
        try FileManager.default.moveItem(at: snapshotURL, to: deletionURL)

        XCTAssertEqual(try store.load().backups, [record])
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshotURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: deletionURL.path))
    }

    func testCatalogStoreFinishesCommittedDeletionTombstone() throws {
        let root = try makeTemporaryDirectory()
        let paths = TimeMachinePaths(rootURL: root, bundleIdentifier: "com.phibrowser.Mac")
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000609")!
        let deletionURL = paths.snapshotsRootURL.appendingPathComponent("\(id.uuidString).deleting")
        let externalURL = root.appendingPathComponent("External", isDirectory: true)
        let markerURL = externalURL.appendingPathComponent("keep.txt")
        try FileManager.default.createDirectory(at: deletionURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: externalURL, withIntermediateDirectories: true)
        try "keep".write(to: markerURL, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: deletionURL.appendingPathComponent("external-link"),
            withDestinationURL: externalURL
        )
        let store = TimeMachineCatalogStore(paths: paths)
        try store.save(TimeMachineCatalog())

        XCTAssertTrue(try store.load().backups.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: deletionURL.path))

        try store.purgeCommittedDeletionTombstones()

        XCTAssertFalse(FileManager.default.fileExists(atPath: deletionURL.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: paths.snapshotsRootURL.appendingPathComponent("\(id.uuidString).purging").path
        ))
        XCTAssertTrue(FileManager.default.fileExists(atPath: markerURL.path))
    }

    func testCatalogStoreFinishesInterruptedPurgingTombstone() throws {
        let root = try makeTemporaryDirectory()
        let paths = TimeMachinePaths(rootURL: root, bundleIdentifier: "com.phibrowser.Mac")
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000616")!
        let purgingURL = paths.snapshotsRootURL.appendingPathComponent("\(id.uuidString).purging")
        let externalURL = root.appendingPathComponent("External", isDirectory: true)
        let markerURL = externalURL.appendingPathComponent("keep.txt")
        try FileManager.default.createDirectory(at: purgingURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: externalURL, withIntermediateDirectories: true)
        try "keep".write(to: markerURL, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: purgingURL.appendingPathComponent("external-link"),
            withDestinationURL: externalURL
        )
        let store = TimeMachineCatalogStore(paths: paths)
        try store.save(TimeMachineCatalog())

        XCTAssertTrue(try store.load().backups.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: purgingURL.path))

        try store.purgeCommittedDeletionTombstones()

        XCTAssertFalse(FileManager.default.fileExists(atPath: purgingURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: markerURL.path))
    }

    func testCatalogStoreRestoresPurgingSnapshotWhenCatalogRecordSurvives() throws {
        let root = try makeTemporaryDirectory()
        let paths = TimeMachinePaths(rootURL: root, bundleIdentifier: "com.phibrowser.Mac")
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000617")!
        let snapshotURL = paths.snapshotURL(id: id)
        let purgingURL = paths.snapshotsRootURL.appendingPathComponent("\(id.uuidString).purging")
        try FileManager.default.createDirectory(at: purgingURL, withIntermediateDirectories: true)
        let record = try makeBackupRecord(
            id: id,
            snapshotRelativePath: paths.relativePath(for: snapshotURL)
        )
        let store = TimeMachineCatalogStore(paths: paths)
        try store.save(TimeMachineCatalog(backups: [record]))

        XCTAssertEqual(try store.load().backups, [record])

        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshotURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: purgingURL.path))
    }

    func testCatalogStoreFailsClosedWhenFinalSnapshotAndTombstoneBothExist() throws {
        let root = try makeTemporaryDirectory()
        let paths = TimeMachinePaths(rootURL: root, bundleIdentifier: "com.phibrowser.Mac")
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000610")!
        let snapshotURL = paths.snapshotURL(id: id)
        let deletionURL = paths.snapshotsRootURL.appendingPathComponent("\(id.uuidString).deleting")
        try FileManager.default.createDirectory(at: snapshotURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: deletionURL, withIntermediateDirectories: true)
        let record = try makeBackupRecord(
            id: id,
            snapshotRelativePath: paths.relativePath(for: snapshotURL)
        )
        let store = TimeMachineCatalogStore(paths: paths)
        try store.save(TimeMachineCatalog(backups: [record]))

        XCTAssertThrowsError(try store.load()) { error in
            guard case TimeMachineCatalogStoreError.conflictingSnapshotEntries(id) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshotURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: deletionURL.path))
    }

    func testPolicyLoaderReadsBundledPolicyJSON() throws {
        let directory = try makeTemporaryDirectory()
        let policyURL = directory.appendingPathComponent("TimeMachineRollbackPolicy.json")
        try """
        {
          "backupTriggerBuild": 600,
          "backupTriggerVersion": "2.0",
          "rollbackVersion": "1.6",
          "rollbackBuild": 590,
          "rollbackPackageURL": "https://example.com/Phi-1.6-590.zip",
          "rollbackPackageSHA256": "abc123",
          "includeChromiumData": true,
          "rollbackAppBundleName": "Phi Canary.app"
        }
        """.data(using: .utf8)!.write(to: policyURL)

        let loader = TimeMachineRollbackPolicyLoader(policyURLProvider: { policyURL })

        let policy = try XCTUnwrap(try loader.loadPolicy())
        XCTAssertEqual(policy.backupTriggerBuild, 600)
        XCTAssertEqual(policy.backupTriggerVersion, "2.0")
        XCTAssertEqual(policy.rollbackVersion, "1.6")
        XCTAssertEqual(policy.rollbackBuild, 590)
        XCTAssertEqual(policy.rollbackPackageSHA256, "abc123")
        XCTAssertTrue(policy.includeChromiumData)
        XCTAssertEqual(policy.rollbackAppBundleName, "Phi Canary.app")
    }

    private func makeBackupRecord(id: UUID, snapshotRelativePath: String) throws -> TimeMachineBackupRecord {
        TimeMachineBackupRecord(
            id: id,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            creatingVersion: "2.0",
            creatingBuild: 600,
            backupTriggerBuild: 600,
            rollbackVersion: "1.6.0",
            rollbackBuild: 590,
            rollbackPackageURL: try XCTUnwrap(URL(string: "https://example.com/Phi-1.6-590.zip")),
            rollbackPackageSHA256: "abc123",
            includeChromiumData: true,
            snapshotRelativePath: snapshotRelativePath,
            status: .completed
        )
    }

    func testPolicyLoaderRejectsNestedRollbackAppBundleName() throws {
        let directory = try makeTemporaryDirectory()
        let policyURL = directory.appendingPathComponent("TimeMachineRollbackPolicy.json")
        try """
        {
          "backupTriggerBuild": 600,
          "backupTriggerVersion": "2.0",
          "rollbackVersion": "1.6",
          "rollbackBuild": 590,
          "rollbackPackageURL": "https://example.com/Phi-1.6-590.zip",
          "rollbackPackageSHA256": "abc123",
          "includeChromiumData": true,
          "rollbackAppBundleName": "Nested/Phi Canary.app"
        }
        """.data(using: .utf8)!.write(to: policyURL)

        let loader = TimeMachineRollbackPolicyLoader(policyURLProvider: { policyURL })

        XCTAssertThrowsError(try loader.loadPolicy()) { error in
            guard case TimeMachineRollbackPolicyLoaderError.invalidPolicy = error else {
                return XCTFail("Expected invalid policy, got \(error).")
            }
        }
    }

    func testPolicyLoaderRejectsEmptyBackupTriggerVersion() throws {
        let directory = try makeTemporaryDirectory()
        let policyURL = directory.appendingPathComponent("TimeMachineRollbackPolicy.json")
        try """
        {
          "backupTriggerBuild": 600,
          "backupTriggerVersion": "   ",
          "rollbackVersion": "1.6",
          "rollbackBuild": 590,
          "rollbackPackageURL": "https://example.com/Phi-1.6-590.zip",
          "rollbackPackageSHA256": "abc123",
          "includeChromiumData": true
        }
        """.data(using: .utf8)!.write(to: policyURL)

        let loader = TimeMachineRollbackPolicyLoader(policyURLProvider: { policyURL })

        XCTAssertThrowsError(try loader.loadPolicy()) { error in
            guard case TimeMachineRollbackPolicyLoaderError.invalidPolicy = error else {
                return XCTFail("Expected invalid policy, got \(error).")
            }
        }
    }

    func testJournalPersistsPhaseAndReportsRecoveryNeed() throws {
        let root = try makeTemporaryDirectory()
        let paths = TimeMachinePaths(rootURL: root, bundleIdentifier: "com.phibrowser.Mac")
        let operationID = UUID(uuidString: "00000000-0000-0000-0000-000000000601")!
        let store = TimeMachineRestoreJournalStore(paths: paths)

        try store.write(
            TimeMachineRestoreJournal(
                operationID: operationID,
                phase: .dataSwapped,
                updatedAt: Date(timeIntervalSince1970: 1_781_020_800),
                planRelativePath: "Pending/\(operationID.uuidString)/install-plan.json",
                helperRelativePath: "Pending/\(operationID.uuidString)/PhiTimeMachineInstaller"
            )
        )

        let pending = try store.pendingJournalsNeedingRecovery()
        XCTAssertEqual(pending.map(\.operationID), [operationID])
        XCTAssertTrue(TimeMachineRestorePhase.dataSwapStarted.needsRecovery)
        XCTAssertTrue(TimeMachineRestorePhase.dataSwapped.needsRecovery)
        XCTAssertTrue(TimeMachineRestorePhase.appSwapStarted.needsRecovery)
        XCTAssertTrue(TimeMachineRestorePhase.dataSwapStarted.hasStartedDestructiveSwap)
        XCTAssertFalse(TimeMachineRestorePhase.dataBackedUp.hasStartedDestructiveSwap)
        XCTAssertFalse(TimeMachineRestorePhase.completed.needsRecovery)
        XCTAssertFalse(TimeMachineRestorePhase.failed.needsRecovery)
        XCTAssertFalse(TimeMachineRestorePhase.reverted.needsRecovery)
    }

    func testSentryTraceStoreDrainsPersistedRecoveryTrace() throws {
        let root = try makeTemporaryDirectory()
        let paths = TimeMachinePaths(rootURL: root, bundleIdentifier: "com.phibrowser.Mac")
        let trace = TimeMachineRestoreRecoveryTrace(
            status: .blocked,
            operationID: UUID(uuidString: "00000000-0000-0000-0000-000000000602")!,
            bundleIdentifier: "com.phibrowser.Mac",
            phase: .dataSwapped,
            hasStartedDestructiveSwap: true,
            reason: "helper launch failed",
            errorDescription: "launch failed",
            errorType: "TimeMachineTestError"
        )

        try TimeMachineSentryTraceStore(paths: paths).append(.restoreRecovery(trace))
        let drainedTraces = try TimeMachineSentryTraceStore(paths: paths).drain()

        XCTAssertEqual(drainedTraces, [.restoreRecovery(trace)])
        XCTAssertEqual(try TimeMachineSentryTraceStore(paths: paths).drain(), [])
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: "/Users/Shared", isDirectory: true)
            .appendingPathComponent("TimeMachineCoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryDirectories.append(url)
        return url
    }
}

private struct LegacyTimeMachineCatalog: Decodable {
    let backups: [TimeMachineBackupRecord]
}

private enum TimeMachineCatalogStoreTestError: Error {
    case writeFailed
}

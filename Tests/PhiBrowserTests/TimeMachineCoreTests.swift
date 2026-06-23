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

    func testPolicyMatchesOnlyExactTriggerBuild() throws {
        let policy = TimeMachineRollbackPolicy(
            backupTriggerBuild: 600,
            rollbackVersion: "1.6",
            rollbackBuild: 590,
            rollbackPackageURL: try XCTUnwrap(URL(string: "https://example.com/Phi-1.6-590.zip")),
            rollbackPackageSHA256: "abc123",
            includeChromiumData: true
        )

        XCTAssertTrue(policy.shouldCreateBackup(forBuild: 600))
        XCTAssertFalse(policy.shouldCreateBackup(forBuild: 599))
        XCTAssertFalse(policy.shouldCreateBackup(forBuild: 601))
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
            rollbackVersion: "1.6",
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
        XCTAssertEqual(loaded.completedBackups.first?.menuTitle(timeZone: TimeZone(secondsFromGMT: 0)!), "Phi 1.6 build 590 on 2026.6.11")
        XCTAssertTrue(loaded.hasCompletedBackup(triggerBuild: 600))
        XCTAssertFalse(loaded.hasCompletedBackup(triggerBuild: 601))
    }

    func testPolicyLoaderReadsBundledPolicyJSON() throws {
        let directory = try makeTemporaryDirectory()
        let policyURL = directory.appendingPathComponent("TimeMachineRollbackPolicy.json")
        try """
        {
          "backupTriggerBuild": 600,
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
        XCTAssertEqual(policy.rollbackVersion, "1.6")
        XCTAssertEqual(policy.rollbackBuild, 590)
        XCTAssertEqual(policy.rollbackPackageSHA256, "abc123")
        XCTAssertTrue(policy.includeChromiumData)
        XCTAssertEqual(policy.rollbackAppBundleName, "Phi Canary.app")
    }

    func testPolicyLoaderRejectsNestedRollbackAppBundleName() throws {
        let directory = try makeTemporaryDirectory()
        let policyURL = directory.appendingPathComponent("TimeMachineRollbackPolicy.json")
        try """
        {
          "backupTriggerBuild": 600,
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

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TimeMachineCoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryDirectories.append(url)
        return url
    }
}

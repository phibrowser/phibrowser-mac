// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

final class TimeMachineBootstrapTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
    }

    func testIncompleteJournalLaunchesRecoveryAndBlocksStartup() throws {
        let fixture = try makeFixture()
        let operationID = UUID(uuidString: "00000000-0000-0000-0000-000000000800")!
        let helperURL = try writeExecutableHelper(operationID: operationID, paths: fixture.paths)
        try writeJournal(
            operationID: operationID,
            phase: .dataSwapped,
            helperURL: helperURL,
            paths: fixture.paths
        )
        var launches: [(url: URL, arguments: [String])] = []
        let gate = makeGate(fixture: fixture) { url, arguments in
            launches.append((url, arguments))
        }

        XCTAssertTrue(gate.recoverPendingRestoreIfNeeded())

        XCTAssertEqual(launches.count, 1)
        XCTAssertEqual(launches.first?.url, helperURL)
        XCTAssertEqual(
            launches.first?.arguments,
            TimeMachineStartupRecoveryGate.recoveryArguments(operationID: operationID, rootURL: fixture.paths.rootURL)
        )
    }

    func testTerminalJournalPhasesDoNotBlockStartup() throws {
        let fixture = try makeFixture()
        for phase in [TimeMachineRestorePhase.completed, .failed, .reverted] {
            let operationID = UUID()
            try writeJournal(
                operationID: operationID,
                phase: phase,
                helperURL: fixture.paths.pendingOperationURL(id: operationID).appendingPathComponent("PhiTimeMachineInstaller"),
                paths: fixture.paths
            )
        }
        var didLaunch = false
        let gate = makeGate(fixture: fixture) { _, _ in
            didLaunch = true
        }

        XCTAssertFalse(gate.recoverPendingRestoreIfNeeded())
        XCTAssertFalse(didLaunch)
    }

    func testCompletedRestoreCleanupRemovesAllRestoreArtifacts() throws {
        let fixture = try makeFixture()
        let operationID = UUID(uuidString: "00000000-0000-0000-0000-000000000804")!
        let operationURL = fixture.paths.pendingOperationURL(id: operationID)
        let snapshotID = UUID(uuidString: "00000000-0000-0000-0000-000000000805")!
        let snapshotURL = fixture.paths.snapshotURL(id: snapshotID)
        let snapshotApplicationSupportURL = snapshotURL.appendingPathComponent("ApplicationSupport/com.phibrowser.Mac", isDirectory: true)
        let emergencyURL = fixture.paths.emergencyOperationURL(id: operationID)
        let planURL = operationURL.appendingPathComponent("install-plan.json", isDirectory: false)
        let helperURL = try writeExecutableHelper(operationID: operationID, paths: fixture.paths)
        try FileManager.default.createDirectory(at: snapshotApplicationSupportURL, withIntermediateDirectories: true)
        try "snapshot".write(
            to: snapshotApplicationSupportURL.appendingPathComponent("data.txt"),
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.createDirectory(at: emergencyURL, withIntermediateDirectories: true)
        try "emergency".write(
            to: emergencyURL.appendingPathComponent("data.txt"),
            atomically: true,
            encoding: .utf8
        )
        let plan = TimeMachineInstallPlan(
            operationID: operationID,
            backupID: snapshotID,
            hostPID: 12345,
            bundleIdentifier: "com.phibrowser.Mac",
            currentAppURL: fixture.rootURL.appendingPathComponent("Applications/Phi.app", isDirectory: true),
            stagedAppURL: operationURL.appendingPathComponent("Package/Phi.app", isDirectory: true),
            snapshotURL: snapshotURL,
            currentApplicationSupportURL: fixture.rootURL.appendingPathComponent("Library/Application Support/com.phibrowser.Mac", isDirectory: true),
            snapshotApplicationSupportURL: snapshotApplicationSupportURL,
            currentPhiDataURL: fixture.rootURL.appendingPathComponent("Library/Application Support/com.phibrowser.Mac/Phi", isDirectory: true),
            snapshotPhiDataURL: snapshotApplicationSupportURL.appendingPathComponent("Phi", isDirectory: true),
            currentPreferencesURL: fixture.rootURL.appendingPathComponent("Library/Preferences/com.phibrowser.Mac.plist", isDirectory: false),
            snapshotPreferencesURL: nil,
            emergencyBackupURL: emergencyURL,
            includeChromiumData: true,
            rollbackVersion: "1.6",
            rollbackBuild: 590,
            packageSHA256: "sha"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(plan).write(to: planURL, options: .atomic)
        try writeJournal(
            operationID: operationID,
            phase: .completed,
            helperURL: helperURL,
            paths: fixture.paths
        )
        try TimeMachineCatalogStore(paths: fixture.paths).appendCompletedBackup(
            TimeMachineBackupRecord(
                id: snapshotID,
                createdAt: Date(timeIntervalSince1970: 1_781_020_700),
                creatingVersion: "2.0",
                creatingBuild: 600,
                backupTriggerBuild: 600,
                rollbackVersion: "1.6",
                rollbackBuild: 590,
                rollbackPackageURL: URL(string: "https://example.com/rollback.zip")!,
                rollbackPackageSHA256: "sha",
                includeChromiumData: true,
                snapshotRelativePath: fixture.paths.relativePath(for: snapshotURL),
                status: .completed
            )
        )
        let gate = makeGate(fixture: fixture) { _, _ in }

        XCTAssertFalse(gate.recoverPendingRestoreIfNeeded())

        XCTAssertFalse(FileManager.default.fileExists(atPath: operationURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: emergencyURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshotURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.pendingRootURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.emergencyRootURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.snapshotsRootURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.catalogURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.rootURL.path))
        XCTAssertTrue(try TimeMachineCatalogStore(paths: fixture.paths).load().completedBackups.isEmpty)
    }

    func testEmptyManagedDirectoriesAreCleanedOnStartup() throws {
        let fixture = try makeFixture()
        try FileManager.default.createDirectory(at: fixture.paths.pendingRootURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fixture.paths.emergencyRootURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fixture.paths.snapshotsRootURL, withIntermediateDirectories: true)
        let gate = makeGate(fixture: fixture) { _, _ in }

        XCTAssertFalse(gate.recoverPendingRestoreIfNeeded())

        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.pendingRootURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.emergencyRootURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.snapshotsRootURL.path))
    }

    func testMissingRecoveryHelperAfterDestructiveSwapBlocksStartupWithoutLaunching() throws {
        let fixture = try makeFixture()
        let operationID = UUID(uuidString: "00000000-0000-0000-0000-000000000801")!
        try writeJournal(
            operationID: operationID,
            phase: .appBackedUp,
            helperURL: fixture.paths.pendingOperationURL(id: operationID).appendingPathComponent("MissingHelper"),
            paths: fixture.paths
        )
        var didLaunch = false
        let gate = makeGate(fixture: fixture) { _, _ in
            didLaunch = true
        }

        XCTAssertTrue(gate.recoverPendingRestoreIfNeeded())
        XCTAssertFalse(didLaunch)
    }

    func testMissingRecoveryHelperBeforeDestructiveSwapMarksFailedAndAllowsStartup() throws {
        let fixture = try makeFixture()
        let operationID = UUID(uuidString: "00000000-0000-0000-0000-000000000806")!
        try writeJournal(
            operationID: operationID,
            phase: .dataBackedUp,
            helperURL: fixture.paths.pendingOperationURL(id: operationID).appendingPathComponent("MissingHelper"),
            paths: fixture.paths
        )
        var didLaunch = false
        let gate = makeGate(fixture: fixture) { _, _ in
            didLaunch = true
        }

        XCTAssertFalse(gate.recoverPendingRestoreIfNeeded())
        XCTAssertFalse(didLaunch)

        let journal = try XCTUnwrap(try TimeMachineRestoreJournalStore(paths: fixture.paths).load(operationID: operationID))
        XCTAssertEqual(journal.phase, .failed)
    }

    func testRecoveryLaunchFailureBeforeDestructiveSwapMarksFailedAndAllowsStartup() throws {
        let fixture = try makeFixture()
        let operationID = UUID(uuidString: "00000000-0000-0000-0000-000000000803")!
        let helperURL = try writeExecutableHelper(operationID: operationID, paths: fixture.paths)
        try writeJournal(
            operationID: operationID,
            phase: .dataBackedUp,
            helperURL: helperURL,
            paths: fixture.paths
        )
        let gate = makeGate(fixture: fixture) { _, _ in
            throw CocoaError(.executableLoad)
        }

        XCTAssertFalse(gate.recoverPendingRestoreIfNeeded())

        let journal = try XCTUnwrap(try TimeMachineRestoreJournalStore(paths: fixture.paths).load(operationID: operationID))
        XCTAssertEqual(journal.phase, .failed)
    }

    func testRecoveryLaunchFailureAfterDestructiveSwapBlocksStartup() throws {
        let fixture = try makeFixture()
        let operationID = UUID(uuidString: "00000000-0000-0000-0000-000000000807")!
        let helperURL = try writeExecutableHelper(operationID: operationID, paths: fixture.paths)
        try writeJournal(
            operationID: operationID,
            phase: .dataSwapStarted,
            helperURL: helperURL,
            paths: fixture.paths
        )
        let gate = makeGate(fixture: fixture) { _, _ in
            throw CocoaError(.executableLoad)
        }

        XCTAssertTrue(gate.recoverPendingRestoreIfNeeded())

        let journal = try XCTUnwrap(try TimeMachineRestoreJournalStore(paths: fixture.paths).load(operationID: operationID))
        XCTAssertEqual(journal.phase, .dataSwapStarted)
    }

    func testBackupPreparationIsSkippedWhenRecoveryBlocksStartup() throws {
        let fixture = try makeFixture()
        let operationID = UUID(uuidString: "00000000-0000-0000-0000-000000000802")!
        let helperURL = try writeExecutableHelper(operationID: operationID, paths: fixture.paths)
        try writeJournal(
            operationID: operationID,
            phase: .prepared,
            helperURL: helperURL,
            paths: fixture.paths
        )
        let gate = makeGate(fixture: fixture) { _, _ in }
        var didPrepareBackup = false

        if !gate.recoverPendingRestoreIfNeeded() {
            didPrepareBackup = true
        }

        XCTAssertFalse(didPrepareBackup)
    }

    private struct Fixture {
        let rootURL: URL
        let paths: TimeMachinePaths
    }

    private func makeFixture() throws -> Fixture {
        let rootURL = try makeTemporaryDirectory()
        return Fixture(
            rootURL: rootURL,
            paths: TimeMachinePaths(rootURL: rootURL.appendingPathComponent("TimeMachine", isDirectory: true))
        )
    }

    private func makeGate(
        fixture: Fixture,
        recoveryLauncher: @escaping TimeMachineStartupRecoveryGate.RecoveryLauncher
    ) -> TimeMachineStartupRecoveryGate {
        TimeMachineStartupRecoveryGate(
            paths: fixture.paths,
            journalStore: TimeMachineRestoreJournalStore(paths: fixture.paths),
            recoveryLauncher: recoveryLauncher,
            dateProvider: { Date(timeIntervalSince1970: 1_781_020_801) },
            logger: { _ in }
        )
    }

    private func writeExecutableHelper(operationID: UUID, paths: TimeMachinePaths) throws -> URL {
        let helperURL = paths.pendingOperationURL(id: operationID).appendingPathComponent("PhiTimeMachineInstaller")
        try FileManager.default.createDirectory(at: helperURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\nexit 0\n".write(to: helperURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helperURL.path)
        return helperURL
    }

    private func writeJournal(
        operationID: UUID,
        phase: TimeMachineRestorePhase,
        helperURL: URL,
        paths: TimeMachinePaths
    ) throws {
        let journal = TimeMachineRestoreJournal(
            operationID: operationID,
            phase: phase,
            updatedAt: Date(timeIntervalSince1970: 1_781_020_800),
            planRelativePath: paths.relativePath(
                for: paths.pendingOperationURL(id: operationID).appendingPathComponent("install-plan.json")
            ),
            helperRelativePath: paths.relativePath(for: helperURL)
        )
        try TimeMachineRestoreJournalStore(paths: paths).write(journal)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TimeMachineBootstrapTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryDirectories.append(url)
        return url
    }
}

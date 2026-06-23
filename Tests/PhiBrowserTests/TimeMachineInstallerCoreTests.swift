// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

final class TimeMachineInstallerCoreTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
    }

    func testDataIsStagedBeforeLivePathsAreTouched() throws {
        let fixture = try makeFixture(includeChromiumData: true)
        var phases: [TimeMachineRestorePhase] = []
        let core = makeCore(fixture: fixture) { phase in
            phases.append(phase)
            if phase == .dataStaged {
                throw CocoaError(.userCancelled)
            }
        }

        XCTAssertThrowsError(try core.restore(planURL: fixture.planURL))

        XCTAssertEqual(phases, [.dataStaged, .failed])
        XCTAssertTrue(fileExists(fixture.operationURL.appendingPathComponent("DataStaging/ApplicationSupport/Phi/local-store.txt")))
        XCTAssertEqual(try readText(fixture.currentPhiDataURL.appendingPathComponent("local-store.txt")), "current-local")
        XCTAssertEqual(try readText(fixture.currentApplicationSupportURL.appendingPathComponent("Default/chrome.txt")), "current-chrome")
    }

    func testSuccessfulRestoreReplacesFullApplicationSupportAndAdvancesJournal() throws {
        let fixture = try makeFixture(includeChromiumData: true)
        var phases: [TimeMachineRestorePhase] = []
        var openedAppURL: URL?
        let core = makeCore(fixture: fixture, appOpener: { openedAppURL = $0 }) { phase in
            phases.append(phase)
        }

        try core.restore(planURL: fixture.planURL)

        XCTAssertEqual(phases, [.dataStaged, .dataBackedUp, .dataSwapStarted, .dataSwapped, .appBackedUp, .appSwapStarted, .appSwapped, .completed])
        XCTAssertEqual(try readText(fixture.currentPhiDataURL.appendingPathComponent("local-store.txt")), "rollback-local")
        XCTAssertEqual(try readText(fixture.currentApplicationSupportURL.appendingPathComponent("Default/chrome.txt")), "rollback-chrome")
        XCTAssertFalse(fileExists(fixture.currentApplicationSupportURL.appendingPathComponent("CurrentOnly.txt")))
        XCTAssertEqual(try readText(fixture.preferencesURL), "rollback-prefs")
        XCTAssertEqual(try readText(fixture.currentAppURL.appendingPathComponent("Contents/build.txt")), "rollback-app")
        XCTAssertEqual(openedAppURL, fixture.currentAppURL)

        XCTAssertNil(try TimeMachineRestoreJournalStore(paths: fixture.paths).load(operationID: fixture.operationID))
        XCTAssertFalse(fileExists(fixture.operationURL))
        XCTAssertFalse(fileExists(fixture.paths.emergencyOperationURL(id: fixture.operationID)))
        XCTAssertFalse(fileExists(fixture.snapshotURL))
        XCTAssertFalse(fileExists(fixture.paths.pendingRootURL))
        XCTAssertFalse(fileExists(fixture.paths.emergencyRootURL))
        XCTAssertFalse(fileExists(fixture.paths.snapshotsRootURL))
        XCTAssertFalse(fileExists(fixture.paths.catalogURL))
        XCTAssertFalse(fileExists(fixture.paths.rootURL))
        XCTAssertTrue(try TimeMachineCatalogStore(paths: fixture.paths).load().completedBackups.isEmpty)
    }

    func testFailureAfterDataSwapRestoresEmergencyBackups() throws {
        let fixture = try makeFixture(includeChromiumData: true)
        var phases: [TimeMachineRestorePhase] = []
        let core = makeCore(fixture: fixture) { phase in
            phases.append(phase)
            if phase == .dataSwapped {
                throw CocoaError(.fileWriteUnknown)
            }
        }

        XCTAssertThrowsError(try core.restore(planURL: fixture.planURL))

        XCTAssertEqual(phases, [.dataStaged, .dataBackedUp, .dataSwapStarted, .dataSwapped, .reverted])
        XCTAssertEqual(try readText(fixture.currentPhiDataURL.appendingPathComponent("local-store.txt")), "current-local")
        XCTAssertEqual(try readText(fixture.currentApplicationSupportURL.appendingPathComponent("Default/chrome.txt")), "current-chrome")
        XCTAssertEqual(try readText(fixture.preferencesURL), "current-prefs")
        XCTAssertEqual(try readText(fixture.currentAppURL.appendingPathComponent("Contents/build.txt")), "current-app")

        let journal = try XCTUnwrap(try TimeMachineRestoreJournalStore(paths: fixture.paths).load(operationID: fixture.operationID))
        XCTAssertEqual(journal.phase, .reverted)
    }

    func testFailureInsideDataSwapRestoresEmergencyBackups() throws {
        let fixture = try makeFixture(includeChromiumData: true, invalidPreferencesParent: true)
        var phases: [TimeMachineRestorePhase] = []
        let core = makeCore(fixture: fixture) { phase in
            phases.append(phase)
        }

        XCTAssertThrowsError(try core.restore(planURL: fixture.planURL))

        XCTAssertEqual(phases, [.dataStaged, .dataBackedUp, .dataSwapStarted, .reverted])
        XCTAssertEqual(try readText(fixture.currentPhiDataURL.appendingPathComponent("local-store.txt")), "current-local")
        XCTAssertEqual(try readText(fixture.currentApplicationSupportURL.appendingPathComponent("Default/chrome.txt")), "current-chrome")
        XCTAssertEqual(try readText(fixture.currentAppURL.appendingPathComponent("Contents/build.txt")), "current-app")

        let journal = try XCTUnwrap(try TimeMachineRestoreJournalStore(paths: fixture.paths).load(operationID: fixture.operationID))
        XCTAssertEqual(journal.phase, .reverted)
    }

    func testRecoveryFromAppSwapStartedRestoresEmergencyBackupsWhenStagedAppIsGone() throws {
        let fixture = try makeFixture(includeChromiumData: true)
        try prepareAppSwapStartedCrashState(fixture: fixture)
        let core = makeCore(fixture: fixture) { _ in }

        XCTAssertThrowsError(try core.recover(operationID: fixture.operationID))

        XCTAssertEqual(try readText(fixture.currentPhiDataURL.appendingPathComponent("local-store.txt")), "current-local")
        XCTAssertEqual(try readText(fixture.currentApplicationSupportURL.appendingPathComponent("Default/chrome.txt")), "current-chrome")
        XCTAssertEqual(try readText(fixture.preferencesURL), "current-prefs")
        XCTAssertEqual(try readText(fixture.currentAppURL.appendingPathComponent("Contents/build.txt")), "current-app")

        let journal = try XCTUnwrap(try TimeMachineRestoreJournalStore(paths: fixture.paths).load(operationID: fixture.operationID))
        XCTAssertEqual(journal.phase, .reverted)
    }

    func testSentinelTerminationRunsBeforeDataStagingAndDoesNotAbortRestore() throws {
        let fixture = try makeFixture(includeChromiumData: true)
        var didRequestSentinelTermination = false
        let core = makeCore(
            fixture: fixture,
            sentinelTerminator: { bundleIdentifier in
                XCTAssertEqual(bundleIdentifier, "com.phibrowser.Mac")
                didRequestSentinelTermination = true
                throw CocoaError(.userCancelled)
            }
        ) { phase in
            if phase == .dataStaged {
                XCTAssertTrue(didRequestSentinelTermination)
            }
        }

        try core.restore(planURL: fixture.planURL)

        XCTAssertTrue(didRequestSentinelTermination)
        XCTAssertEqual(try readText(fixture.currentAppURL.appendingPathComponent("Contents/build.txt")), "rollback-app")
    }

    func testRecoveryFromDataStagedRequestsSentinelTerminationBeforeBackupData() throws {
        let fixture = try makeFixture(includeChromiumData: true)
        try stageDataForRecovery(fixture: fixture)
        try writeJournalPhase(.dataStaged, fixture: fixture)
        var didRequestSentinelTermination = false
        let core = makeCore(
            fixture: fixture,
            sentinelTerminator: { _ in
                didRequestSentinelTermination = true
            }
        ) { phase in
            if phase == .dataBackedUp {
                XCTAssertTrue(didRequestSentinelTermination)
                throw CocoaError(.userCancelled)
            }
        }

        XCTAssertThrowsError(try core.recover(operationID: fixture.operationID))

        XCTAssertTrue(didRequestSentinelTermination)
    }

    func testRecoveryFromDataBackedUpRequestsSentinelTerminationBeforeDataSwapStarts() throws {
        let fixture = try makeFixture(includeChromiumData: true)
        try stageDataForRecovery(fixture: fixture)
        try backupDataForRecovery(fixture: fixture)
        try writeJournalPhase(.dataBackedUp, fixture: fixture)
        var didRequestSentinelTermination = false
        let core = makeCore(
            fixture: fixture,
            sentinelTerminator: { _ in
                didRequestSentinelTermination = true
            }
        ) { phase in
            if phase == .dataSwapStarted {
                XCTAssertTrue(didRequestSentinelTermination)
                throw CocoaError(.userCancelled)
            }
        }

        XCTAssertThrowsError(try core.recover(operationID: fixture.operationID))

        XCTAssertTrue(didRequestSentinelTermination)
    }

    func testAppSwapHappensAfterDataSwap() throws {
        let fixture = try makeFixture(includeChromiumData: true)
        var phases: [TimeMachineRestorePhase] = []
        let core = makeCore(fixture: fixture) { phase in
            phases.append(phase)
        }

        try core.restore(planURL: fixture.planURL)

        let dataSwapIndex = try XCTUnwrap(phases.firstIndex(of: .dataSwapped))
        let appSwapIndex = try XCTUnwrap(phases.firstIndex(of: .appSwapped))
        XCTAssertLessThan(dataSwapIndex, appSwapIndex)
    }

    private struct Fixture {
        let rootURL: URL
        let paths: TimeMachinePaths
        let operationID: UUID
        let operationURL: URL
        let planURL: URL
        let currentAppURL: URL
        let stagedAppURL: URL
        let currentApplicationSupportURL: URL
        let currentPhiDataURL: URL
        let preferencesURL: URL
        let snapshotURL: URL
        let snapshotApplicationSupportURL: URL
        let snapshotPhiDataURL: URL
        let snapshotPreferencesURL: URL
    }

    private func makeFixture(includeChromiumData: Bool, invalidPreferencesParent: Bool = false) throws -> Fixture {
        let rootURL = try makeTemporaryDirectory()
        let paths = TimeMachinePaths(
            rootURL: rootURL.appendingPathComponent("TimeMachine", isDirectory: true),
            bundleIdentifier: "com.phibrowser.Mac"
        )
        let operationID = UUID(uuidString: "00000000-0000-0000-0000-000000001000")!
        let operationURL = paths.pendingOperationURL(id: operationID)
        try FileManager.default.createDirectory(at: operationURL, withIntermediateDirectories: true)

        let currentAppURL = rootURL.appendingPathComponent("Applications/Phi.app", isDirectory: true)
        let stagedAppURL = operationURL.appendingPathComponent("Package/Phi.app", isDirectory: true)
        try writeApp(at: currentAppURL, marker: "current-app")
        try writeApp(at: stagedAppURL, marker: "rollback-app")

        let currentApplicationSupportURL = rootURL.appendingPathComponent("Library/Application Support/com.phibrowser.Mac", isDirectory: true)
        let currentPhiDataURL = currentApplicationSupportURL.appendingPathComponent("Phi", isDirectory: true)
        let libraryURL = rootURL.appendingPathComponent("Library", isDirectory: true)
        let preferencesDirectoryURL = libraryURL.appendingPathComponent("Preferences", isDirectory: true)
        let preferencesURL = preferencesDirectoryURL.appendingPathComponent("com.phibrowser.Mac.plist", isDirectory: false)
        try FileManager.default.createDirectory(at: currentPhiDataURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: currentApplicationSupportURL.appendingPathComponent("Default", isDirectory: true),
            withIntermediateDirectories: true
        )
        try "current-local".write(
            to: currentPhiDataURL.appendingPathComponent("local-store.txt"),
            atomically: true,
            encoding: .utf8
        )
        try "current-chrome".write(
            to: currentApplicationSupportURL.appendingPathComponent("Default/chrome.txt"),
            atomically: true,
            encoding: .utf8
        )
        try "current-only".write(
            to: currentApplicationSupportURL.appendingPathComponent("CurrentOnly.txt"),
            atomically: true,
            encoding: .utf8
        )
        if invalidPreferencesParent {
            try FileManager.default.createDirectory(at: libraryURL, withIntermediateDirectories: true)
            try "not-a-directory".write(to: preferencesDirectoryURL, atomically: true, encoding: .utf8)
        } else {
            try FileManager.default.createDirectory(at: preferencesURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "current-prefs".write(to: preferencesURL, atomically: true, encoding: .utf8)
        }

        let snapshotID = UUID(uuidString: "00000000-0000-0000-0000-000000001001")!
        let snapshotURL = paths.snapshotURL(id: snapshotID)
        let snapshotApplicationSupportURL = snapshotURL.appendingPathComponent("ApplicationSupport/com.phibrowser.Mac", isDirectory: true)
        let snapshotPhiDataURL = snapshotApplicationSupportURL.appendingPathComponent("Phi", isDirectory: true)
        let snapshotPreferencesURL = snapshotURL.appendingPathComponent("Preferences/com.phibrowser.Mac.plist", isDirectory: false)
        try FileManager.default.createDirectory(at: snapshotPhiDataURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: snapshotApplicationSupportURL.appendingPathComponent("Default", isDirectory: true),
            withIntermediateDirectories: true
        )
        try "rollback-local".write(
            to: snapshotPhiDataURL.appendingPathComponent("local-store.txt"),
            atomically: true,
            encoding: .utf8
        )
        try "rollback-chrome".write(
            to: snapshotApplicationSupportURL.appendingPathComponent("Default/chrome.txt"),
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.createDirectory(at: snapshotPreferencesURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "rollback-prefs".write(to: snapshotPreferencesURL, atomically: true, encoding: .utf8)

        let plan = TimeMachineInstallPlan(
            operationID: operationID,
            backupID: snapshotID,
            hostPID: 12345,
            bundleIdentifier: "com.phibrowser.Mac",
            currentAppURL: currentAppURL,
            stagedAppURL: stagedAppURL,
            snapshotURL: snapshotURL,
            currentApplicationSupportURL: currentApplicationSupportURL,
            snapshotApplicationSupportURL: includeChromiumData ? snapshotApplicationSupportURL : nil,
            currentPhiDataURL: currentPhiDataURL,
            snapshotPhiDataURL: snapshotPhiDataURL,
            currentPreferencesURL: preferencesURL,
            snapshotPreferencesURL: snapshotPreferencesURL,
            emergencyBackupURL: paths.emergencyOperationURL(id: operationID),
            includeChromiumData: includeChromiumData,
            rollbackVersion: "1.6",
            rollbackBuild: 590,
            packageSHA256: "sha"
        )
        let planURL = operationURL.appendingPathComponent("install-plan.json", isDirectory: false)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(plan).write(to: planURL, options: .atomic)

        let journal = TimeMachineRestoreJournal(
            operationID: operationID,
            phase: .prepared,
            updatedAt: Date(timeIntervalSince1970: 1_781_020_800),
            planRelativePath: paths.relativePath(for: planURL),
            helperRelativePath: "Pending/\(operationID.uuidString)/PhiTimeMachineInstaller"
        )
        try TimeMachineRestoreJournalStore(paths: paths).write(journal)
        try TimeMachineCatalogStore(paths: paths).appendCompletedBackup(
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
                includeChromiumData: includeChromiumData,
                snapshotRelativePath: paths.relativePath(for: snapshotURL),
                status: .completed
            )
        )

        return Fixture(
            rootURL: rootURL,
            paths: paths,
            operationID: operationID,
            operationURL: operationURL,
            planURL: planURL,
            currentAppURL: currentAppURL,
            stagedAppURL: stagedAppURL,
            currentApplicationSupportURL: currentApplicationSupportURL,
            currentPhiDataURL: currentPhiDataURL,
            preferencesURL: preferencesURL,
            snapshotURL: snapshotURL,
            snapshotApplicationSupportURL: snapshotApplicationSupportURL,
            snapshotPhiDataURL: snapshotPhiDataURL,
            snapshotPreferencesURL: snapshotPreferencesURL
        )
    }

    private func makeCore(
        fixture: Fixture,
        sentinelTerminator: @escaping TimeMachineInstallerCore.SentinelTerminator = { _ in },
        appOpener: @escaping TimeMachineInstallerCore.AppOpener = { _ in },
        logger: @escaping TimeMachineInstallerCore.Logger = { _ in },
        phaseObserver: @escaping TimeMachineInstallerCore.PhaseObserver
    ) -> TimeMachineInstallerCore {
        TimeMachineInstallerCore(
            paths: fixture.paths,
            journalStore: TimeMachineRestoreJournalStore(paths: fixture.paths),
            hostWaiter: { _ in },
            sentinelTerminator: sentinelTerminator,
            appOpener: appOpener,
            dateProvider: { Date(timeIntervalSince1970: 1_781_020_801) },
            phaseObserver: phaseObserver,
            logger: logger
        )
    }

    private func writeJournalPhase(_ phase: TimeMachineRestorePhase, fixture: Fixture) throws {
        try TimeMachineRestoreJournalStore(paths: fixture.paths).write(
            TimeMachineRestoreJournal(
                operationID: fixture.operationID,
                phase: phase,
                updatedAt: Date(timeIntervalSince1970: 1_781_020_801),
                planRelativePath: fixture.paths.relativePath(for: fixture.planURL),
                helperRelativePath: "Pending/\(fixture.operationID.uuidString)/PhiTimeMachineInstaller"
            )
        )
    }

    private func stageDataForRecovery(fixture: Fixture) throws {
        let dataStagingURL = fixture.operationURL.appendingPathComponent("DataStaging", isDirectory: true)
        try copyItemReplacing(
            fixture.snapshotApplicationSupportURL,
            to: dataStagingURL.appendingPathComponent("ApplicationSupport", isDirectory: true)
        )
        try copyItemReplacing(
            fixture.snapshotPreferencesURL,
            to: dataStagingURL.appendingPathComponent("Preferences", isDirectory: false)
        )
    }

    private func backupDataForRecovery(fixture: Fixture) throws {
        let dataBackupURL = fixture.paths.emergencyOperationURL(id: fixture.operationID)
            .appendingPathComponent("Data", isDirectory: true)
        try copyItemReplacing(
            fixture.currentApplicationSupportURL,
            to: dataBackupURL.appendingPathComponent("ApplicationSupport", isDirectory: true)
        )
        try copyItemReplacing(
            fixture.preferencesURL,
            to: dataBackupURL.appendingPathComponent("Preferences", isDirectory: false)
        )
    }

    private func prepareAppSwapStartedCrashState(fixture: Fixture) throws {
        let emergencyURL = fixture.paths.emergencyOperationURL(id: fixture.operationID)
        let dataBackupURL = emergencyURL.appendingPathComponent("Data", isDirectory: true)
        let appBackupURL = emergencyURL.appendingPathComponent("App", isDirectory: true)

        try copyItemReplacing(
            fixture.currentApplicationSupportURL,
            to: dataBackupURL.appendingPathComponent("ApplicationSupport", isDirectory: true)
        )
        try copyItemReplacing(
            fixture.preferencesURL,
            to: dataBackupURL.appendingPathComponent("Preferences", isDirectory: false)
        )
        try copyItemReplacing(
            fixture.currentAppURL,
            to: appBackupURL.appendingPathComponent(fixture.currentAppURL.lastPathComponent, isDirectory: true)
        )

        try copyItemReplacing(fixture.snapshotApplicationSupportURL, to: fixture.currentApplicationSupportURL)
        try copyItemReplacing(fixture.snapshotPreferencesURL, to: fixture.preferencesURL)
        try moveItemReplacing(fixture.stagedAppURL, to: fixture.currentAppURL)

        try TimeMachineRestoreJournalStore(paths: fixture.paths).write(
            TimeMachineRestoreJournal(
                operationID: fixture.operationID,
                phase: .appSwapStarted,
                updatedAt: Date(timeIntervalSince1970: 1_781_020_801),
                planRelativePath: fixture.paths.relativePath(for: fixture.planURL),
                helperRelativePath: "Pending/\(fixture.operationID.uuidString)/PhiTimeMachineInstaller"
            )
        )
    }

    private func copyItemReplacing(_ sourceURL: URL, to destinationURL: URL) throws {
        try removeItemIfExists(destinationURL)
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
    }

    private func moveItemReplacing(_ sourceURL: URL, to destinationURL: URL) throws {
        try removeItemIfExists(destinationURL)
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
    }

    private func removeItemIfExists(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func writeApp(at appURL: URL, marker: String) throws {
        let contentsURL = appURL.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)
        try marker.write(to: contentsURL.appendingPathComponent("build.txt"), atomically: true, encoding: .utf8)
    }

    private func readText(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    private func fileExists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TimeMachineInstallerCoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryDirectories.append(url)
        return url
    }
}

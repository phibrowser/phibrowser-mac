// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

final class TimeMachineRestoreCoordinatorTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
    }

    func testPackageSHA256MismatchFails() throws {
        let fileURL = try makeTemporaryDirectory().appendingPathComponent("package.zip")
        try "not-the-package".write(to: fileURL, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(
            try TimeMachinePackageDownloader.verifySHA256(
                fileURL: fileURL,
                expectedSHA256: String(repeating: "0", count: 64)
            )
        ) { error in
            guard case TimeMachinePackageDownloaderError.sha256Mismatch = error else {
                return XCTFail("Expected SHA-256 mismatch, got \(error).")
            }
        }
    }

    func testBundledHelperURLFallsBackToContentsHelpers() throws {
        let appURL = try makeTemporaryDirectory().appendingPathComponent("Phi Canary.app", isDirectory: true)
        let contentsURL = appURL.appendingPathComponent("Contents", isDirectory: true)
        let macOSURL = contentsURL.appendingPathComponent("MacOS", isDirectory: true)
        let helpersURL = contentsURL.appendingPathComponent("Helpers", isDirectory: true)
        let executableURL = macOSURL.appendingPathComponent("Phi Canary", isDirectory: false)
        let helperURL = helpersURL.appendingPathComponent(TimeMachineRestoreCoordinator.helperFilename, isDirectory: false)
        try FileManager.default.createDirectory(at: macOSURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: helpersURL, withIntermediateDirectories: true)
        try "#!/bin/sh\nexit 0\n".write(to: executableURL, atomically: true, encoding: .utf8)
        try "#!/bin/sh\nexit 0\n".write(to: helperURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helperURL.path)
        let info: [String: Any] = [
            "CFBundleIdentifier": "com.phibrowser.canary.Mac",
            "CFBundleExecutable": "Phi Canary",
            "CFBundlePackageType": "APPL"
        ]
        let infoData = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try infoData.write(to: contentsURL.appendingPathComponent("Info.plist", isDirectory: false))

        let bundle = try XCTUnwrap(Bundle(url: appURL))

        XCTAssertEqual(TimeMachineRestoreCoordinator.bundledHelperURL(in: bundle), helperURL)
    }

    func testZipWithoutTopLevelPhiAppFails() async throws {
        let fixture = try makeFixture()
        let coordinator = makeCoordinator(fixture: fixture) { _, _, destinationURL in
            try "zip".write(to: destinationURL, atomically: true, encoding: .utf8)
            return destinationURL
        } unzipRunner: { _, arguments in
            let destinationURL = URL(fileURLWithPath: arguments.last!)
            try FileManager.default.createDirectory(
                at: destinationURL.appendingPathComponent("NotPhi.app", isDirectory: true),
                withIntermediateDirectories: true
            )
        }

        await XCTAssertThrowsErrorAsync(
            try await coordinator.prepareAndLaunchRestore(for: fixture.backup)
        ) { error in
            guard case TimeMachineRestoreCoordinatorError.missingStagedApp = error else {
                return XCTFail("Expected missing staged app, got \(error).")
            }
        }
    }

    func testStagedAppBundleIdentifierIsValidated() async throws {
        let fixture = try makeFixture()
        let coordinator = makeCoordinator(fixture: fixture) { _, _, destinationURL in
            try "zip".write(to: destinationURL, atomically: true, encoding: .utf8)
            return destinationURL
        } unzipRunner: { _, arguments in
            let destinationURL = URL(fileURLWithPath: arguments.last!)
            try self.writeApp(
                at: destinationURL.appendingPathComponent("Phi.app", isDirectory: true),
                bundleIdentifier: "com.example.Other",
                build: "590"
            )
        }

        await XCTAssertThrowsErrorAsync(
            try await coordinator.prepareAndLaunchRestore(for: fixture.backup)
        ) { error in
            guard case TimeMachineRestoreCoordinatorError.invalidBundleIdentifier = error else {
                return XCTFail("Expected bundle identifier validation failure, got \(error).")
            }
        }
    }

    func testStagedAppBuildIsValidated() async throws {
        let fixture = try makeFixture()
        let coordinator = makeCoordinator(fixture: fixture) { _, _, destinationURL in
            try "zip".write(to: destinationURL, atomically: true, encoding: .utf8)
            return destinationURL
        } unzipRunner: { _, arguments in
            let destinationURL = URL(fileURLWithPath: arguments.last!)
            try self.writeApp(
                at: destinationURL.appendingPathComponent("Phi.app", isDirectory: true),
                bundleIdentifier: "com.phibrowser.Mac",
                build: "591"
            )
        }

        await XCTAssertThrowsErrorAsync(
            try await coordinator.prepareAndLaunchRestore(for: fixture.backup)
        ) { error in
            guard case TimeMachineRestoreCoordinatorError.invalidBundleVersion = error else {
                return XCTFail("Expected bundle version validation failure, got \(error).")
            }
        }
    }

    func testRestorePlanUsesSelectedBackupAndCopiesHelperBeforeLaunch() async throws {
        let fixture = try makeFixture()
        var downloadedRequest: (url: URL, sha256: String, destinationURL: URL)?
        var launchRequest: (url: URL, arguments: [String])?
        let coordinator = makeCoordinator(fixture: fixture) { sourceURL, sha256, destinationURL in
            downloadedRequest = (sourceURL, sha256, destinationURL)
            try "zip".write(to: destinationURL, atomically: true, encoding: .utf8)
            return destinationURL
        } unzipRunner: { _, arguments in
            let destinationURL = URL(fileURLWithPath: arguments.last!)
            try self.writeApp(
                at: destinationURL.appendingPathComponent("Phi.app", isDirectory: true),
                bundleIdentifier: "com.phibrowser.Mac",
                build: "590"
            )
        } helperLauncher: { url, arguments in
            launchRequest = (url, arguments)
        }

        let plan = try await coordinator.prepareAndLaunchRestore(for: fixture.backup)

        XCTAssertEqual(downloadedRequest?.url, fixture.backup.rollbackPackageURL)
        XCTAssertEqual(downloadedRequest?.sha256, fixture.backup.rollbackPackageSHA256)
        XCTAssertEqual(plan.operationID, fixture.operationID)
        XCTAssertEqual(plan.rollbackVersion, "1.6-selected")
        XCTAssertEqual(plan.rollbackBuild, 590)
        XCTAssertEqual(plan.packageSHA256, "selected-sha")
        XCTAssertEqual(plan.snapshotApplicationSupportURL, fixture.snapshotURL.appendingPathComponent("ApplicationSupport/com.phibrowser.Mac", isDirectory: true))
        XCTAssertEqual(plan.snapshotPreferencesURL, fixture.snapshotURL.appendingPathComponent("Preferences/com.phibrowser.Mac.plist", isDirectory: false))

        let helperURL = fixture.paths.pendingOperationURL(id: fixture.operationID)
            .appendingPathComponent(TimeMachineRestoreCoordinator.helperFilename)
        XCTAssertTrue(FileManager.default.fileExists(atPath: helperURL.path))
        XCTAssertEqual(launchRequest?.url, helperURL)
        XCTAssertEqual(
            launchRequest?.arguments,
            TimeMachineRestoreCoordinator.helperArguments(
                planURL: fixture.paths.pendingOperationURL(id: fixture.operationID)
                    .appendingPathComponent(TimeMachineRestoreCoordinator.installPlanFilename)
            )
        )
        let journal = try XCTUnwrap(
            try TimeMachineRestoreJournalStore(paths: fixture.paths).load(operationID: fixture.operationID)
        )
        XCTAssertEqual(journal.phase, .prepared)
    }

    func testRestoreReportsPreparationProgress() async throws {
        let fixture = try makeFixture()
        var reportedProgress: [TimeMachineRestorePreparationProgress] = []
        let coordinator = makeCoordinator(fixture: fixture) { _, _, destinationURL in
            try "zip".write(to: destinationURL, atomically: true, encoding: .utf8)
            return destinationURL
        } unzipRunner: { _, arguments in
            let destinationURL = URL(fileURLWithPath: arguments.last!)
            try self.writeApp(
                at: destinationURL.appendingPathComponent("Phi.app", isDirectory: true),
                bundleIdentifier: "com.phibrowser.Mac",
                build: "590"
            )
        } progressHandler: { progress in
            reportedProgress.append(progress)
        }

        _ = try await coordinator.prepareAndLaunchRestore(for: fixture.backup)

        XCTAssertEqual(
            reportedProgress.map(\.stage),
            [
                .preparing,
                .downloadingPackage,
                .expandingPackage,
                .validatingPackage,
                .preparingInstaller,
                .launchingInstaller,
                .readyToQuit
            ]
        )
        XCTAssertNil(reportedProgress.first { $0.stage == .downloadingPackage }?.fractionCompleted)
        XCTAssertEqual(reportedProgress.last?.fractionCompleted, 1)
    }

    func testCanaryRestorePlanUsesConfiguredAppBundleName() async throws {
        let fixture = try makeFixture(
            bundleIdentifier: "com.phibrowser.canary.Mac",
            currentAppName: "Phi Canary.app",
            rollbackAppBundleName: "Phi Canary.app"
        )
        let coordinator = makeCoordinator(fixture: fixture) { _, _, destinationURL in
            try "zip".write(to: destinationURL, atomically: true, encoding: .utf8)
            return destinationURL
        } unzipRunner: { _, arguments in
            let destinationURL = URL(fileURLWithPath: arguments.last!)
            try self.writeApp(
                at: destinationURL.appendingPathComponent("Phi Canary.app", isDirectory: true),
                bundleIdentifier: "com.phibrowser.canary.Mac",
                build: "590"
            )
        }

        let plan = try await coordinator.prepareAndLaunchRestore(for: fixture.backup)

        XCTAssertEqual(plan.bundleIdentifier, "com.phibrowser.canary.Mac")
        XCTAssertEqual(plan.currentAppURL.lastPathComponent, "Phi Canary.app")
        XCTAssertEqual(plan.stagedAppURL.lastPathComponent, "Phi Canary.app")
        XCTAssertEqual(
            plan.snapshotApplicationSupportURL,
            fixture.snapshotURL.appendingPathComponent("ApplicationSupport/com.phibrowser.canary.Mac", isDirectory: true)
        )
        XCTAssertEqual(
            plan.snapshotPreferencesURL,
            fixture.snapshotURL.appendingPathComponent("Preferences/com.phibrowser.canary.Mac.plist", isDirectory: false)
        )
    }

    func testCanaryRestorePlanInfersAppBundleNameForLegacyBackupRecord() async throws {
        let fixture = try makeFixture(
            bundleIdentifier: "com.phibrowser.canary.Mac",
            currentAppName: "Phi Canary.app"
        )
        let coordinator = makeCoordinator(fixture: fixture) { _, _, destinationURL in
            try "zip".write(to: destinationURL, atomically: true, encoding: .utf8)
            return destinationURL
        } unzipRunner: { _, arguments in
            let destinationURL = URL(fileURLWithPath: arguments.last!)
            try self.writeApp(
                at: destinationURL.appendingPathComponent("Phi Canary.app", isDirectory: true),
                bundleIdentifier: "com.phibrowser.canary.Mac",
                build: "590"
            )
        }

        let plan = try await coordinator.prepareAndLaunchRestore(for: fixture.backup)

        XCTAssertNil(fixture.backup.rollbackAppBundleName)
        XCTAssertEqual(plan.stagedAppURL.lastPathComponent, "Phi Canary.app")
    }

    private struct Fixture {
        let rootURL: URL
        let paths: TimeMachinePaths
        let operationID: UUID
        let helperURL: URL
        let currentAppURL: URL
        let applicationSupportURL: URL
        let phiDataURL: URL
        let preferencesURL: URL
        let snapshotURL: URL
        let backup: TimeMachineBackupRecord
    }

    private func makeFixture(
        bundleIdentifier: String = "com.phibrowser.Mac",
        currentAppName: String = "Phi.app",
        rollbackAppBundleName: String? = nil
    ) throws -> Fixture {
        let rootURL = try makeTemporaryDirectory()
        let paths = TimeMachinePaths(
            rootURL: rootURL.appendingPathComponent("TimeMachine", isDirectory: true),
            bundleIdentifier: bundleIdentifier
        )
        let operationID = UUID(uuidString: "00000000-0000-0000-0000-000000000900")!
        let helperURL = rootURL.appendingPathComponent("Helper/PhiTimeMachineInstaller", isDirectory: false)
        try FileManager.default.createDirectory(at: helperURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "helper".write(to: helperURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helperURL.path)

        let currentAppURL = rootURL.appendingPathComponent("Current/\(currentAppName)", isDirectory: true)
        let applicationSupportURL = rootURL.appendingPathComponent(
            "Current/Application Support/\(bundleIdentifier)",
            isDirectory: true
        )
        let phiDataURL = applicationSupportURL.appendingPathComponent("Phi", isDirectory: true)
        let preferencesURL = rootURL.appendingPathComponent(
            "Current/Preferences/\(bundleIdentifier).plist",
            isDirectory: false
        )
        try FileManager.default.createDirectory(at: phiDataURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: preferencesURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "prefs".write(to: preferencesURL, atomically: true, encoding: .utf8)

        let snapshotURL = paths.snapshotURL(id: UUID(uuidString: "00000000-0000-0000-0000-000000000901")!)
        try FileManager.default.createDirectory(
            at: snapshotURL.appendingPathComponent("ApplicationSupport/\(bundleIdentifier)/Phi", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: snapshotURL.appendingPathComponent("Preferences", isDirectory: true),
            withIntermediateDirectories: true
        )
        try "prefs".write(
            to: snapshotURL.appendingPathComponent("Preferences/\(bundleIdentifier).plist", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )

        let backup = TimeMachineBackupRecord(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000902")!,
            createdAt: Date(timeIntervalSince1970: 1_781_020_800),
            creatingVersion: "2.0",
            creatingBuild: 600,
            backupTriggerBuild: 600,
            rollbackVersion: "1.6-selected",
            rollbackBuild: 590,
            rollbackPackageURL: URL(string: "https://example.com/selected.zip")!,
            rollbackPackageSHA256: "selected-sha",
            includeChromiumData: true,
            snapshotRelativePath: paths.relativePath(for: snapshotURL),
            status: .completed,
            rollbackAppBundleName: rollbackAppBundleName
        )

        return Fixture(
            rootURL: rootURL,
            paths: paths,
            operationID: operationID,
            helperURL: helperURL,
            currentAppURL: currentAppURL,
            applicationSupportURL: applicationSupportURL,
            phiDataURL: phiDataURL,
            preferencesURL: preferencesURL,
            snapshotURL: snapshotURL,
            backup: backup
        )
    }

    private func makeCoordinator(
        fixture: Fixture,
        packageDownloader: @escaping TimeMachineRestoreCoordinator.PackageDownloader,
        unzipRunner: @escaping TimeMachineRestoreCoordinator.ProcessRunner,
        helperLauncher: @escaping TimeMachineRestoreCoordinator.ProcessRunner = { _, _ in },
        progressHandler: TimeMachineRestoreCoordinator.ProgressHandler? = nil
    ) -> TimeMachineRestoreCoordinator {
        TimeMachineRestoreCoordinator(
            paths: fixture.paths,
            packageDownloader: packageDownloader,
            unzipRunner: unzipRunner,
            helperLauncher: helperLauncher,
            helperURLProvider: { fixture.helperURL },
            currentAppURLProvider: { fixture.currentAppURL },
            applicationSupportURLProvider: { fixture.applicationSupportURL },
            phiDataURLProvider: { fixture.phiDataURL },
            preferencesURLProvider: { fixture.preferencesURL },
            operationIDProvider: { fixture.operationID },
            hostPIDProvider: { 12345 },
            journalStore: TimeMachineRestoreJournalStore(paths: fixture.paths),
            progressHandler: progressHandler
        )
    }

    private func writeApp(at appURL: URL, bundleIdentifier: String, build: String) throws {
        let contentsURL = appURL.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": bundleIdentifier,
            "CFBundleVersion": build,
            "CFBundleShortVersionString": "1.6"
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contentsURL.appendingPathComponent("Info.plist", isDirectory: false))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TimeMachineRestoreCoordinatorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryDirectories.append(url)
        return url
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw.", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}

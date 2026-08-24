// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

final class TimeMachineSnapshotTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
    }

    func testFullModeSnapshotsApplicationSupportAndPreferences() throws {
        let fixture = try makeFixture(includePreferences: true)
        try writePolicy(fixture: fixture, includeChromiumData: true)
        let manager = makeManager(fixture: fixture)

        let record = try XCTUnwrap(try manager.prepareBackupIfNeeded(currentVersion: "2.0", currentBuild: 600))

        let snapshotURL = fixture.paths.url(forRelativePath: record.snapshotRelativePath)
        XCTAssertTrue(fileExists(snapshotURL.appendingPathComponent("ApplicationSupport/com.phibrowser.Mac/Phi/local.txt")))
        XCTAssertTrue(fileExists(snapshotURL.appendingPathComponent("ApplicationSupport/com.phibrowser.Mac/Default/chrome.txt")))
        XCTAssertTrue(fileExists(snapshotURL.appendingPathComponent("Preferences/com.phibrowser.Mac.plist")))
        XCTAssertFalse(fileExists(fixture.paths.snapshotStagingURL(id: record.id)))
        let manifest = try readManifest(from: snapshotURL)
        XCTAssertEqual(
            manifest.applicationSupportRelativePath,
            "\(record.snapshotRelativePath)/ApplicationSupport/com.phibrowser.Mac"
        )
        XCTAssertEqual(
            manifest.preferencesRelativePath,
            "\(record.snapshotRelativePath)/Preferences/com.phibrowser.Mac.plist"
        )
        XCTAssertFalse(manifest.applicationSupportRelativePath?.contains(".staging") ?? true)

        let catalog = try TimeMachineCatalogStore(paths: fixture.paths).load()
        XCTAssertEqual(catalog.completedBackups.map(\.id), [record.id])
    }

    func testPhiOnlyModeLeavesChromiumDataOutOfSnapshot() throws {
        let fixture = try makeFixture(includePreferences: true)
        try writePolicy(fixture: fixture, includeChromiumData: false)
        let manager = makeManager(fixture: fixture)

        let record = try XCTUnwrap(try manager.prepareBackupIfNeeded(currentVersion: "2.0", currentBuild: 600))

        let snapshotURL = fixture.paths.url(forRelativePath: record.snapshotRelativePath)
        XCTAssertTrue(fileExists(snapshotURL.appendingPathComponent("ApplicationSupport/com.phibrowser.Mac/Phi/local.txt")))
        XCTAssertFalse(fileExists(snapshotURL.appendingPathComponent("ApplicationSupport/com.phibrowser.Mac/Default/chrome.txt")))
        XCTAssertTrue(fileExists(snapshotURL.appendingPathComponent("Preferences/com.phibrowser.Mac.plist")))
    }

    func testReleaseSnapshotSkipsWhenVersionDoesNotMatchPolicy() throws {
        let fixture = try makeFixture(includePreferences: true)
        try writePolicy(fixture: fixture, includeChromiumData: true)
        let manager = makeManager(fixture: fixture, backupTriggerMode: .version)

        let record = try manager.prepareBackupIfNeeded(currentVersion: "2.0.1", currentBuild: 600)

        XCTAssertNil(record)
        XCTAssertTrue(try TimeMachineCatalogStore(paths: fixture.paths).load().backups.isEmpty)
    }

    func testNightlySnapshotSkipsWhenBuildDoesNotMatchPolicy() throws {
        let fixture = try makeFixture(includePreferences: true)
        try writePolicy(fixture: fixture, includeChromiumData: true)
        let manager = makeManager(fixture: fixture, backupTriggerMode: .build)

        let record = try manager.prepareBackupIfNeeded(currentVersion: "2.0", currentBuild: 601)

        XCTAssertNil(record)
        XCTAssertTrue(try TimeMachineCatalogStore(paths: fixture.paths).load().backups.isEmpty)
    }

    func testReleaseSnapshotDoesNotCreateDuplicateForSameTriggerVersion() throws {
        let fixture = try makeFixture(includePreferences: true)
        try writePolicy(fixture: fixture, includeChromiumData: true)
        let manager = makeManager(fixture: fixture, backupTriggerMode: .version)

        let first = try XCTUnwrap(try manager.prepareBackupIfNeeded(currentVersion: "2.0", currentBuild: 600))
        let second = try manager.prepareBackupIfNeeded(currentVersion: "2.0", currentBuild: 601)

        XCTAssertNil(second)
        let catalog = try TimeMachineCatalogStore(paths: fixture.paths).load()
        XCTAssertEqual(catalog.completedBackups.map(\.id), [first.id])
    }

    func testNightlySnapshotDoesNotCreateDuplicateForSameTriggerBuild() throws {
        let fixture = try makeFixture(includePreferences: true)
        try writePolicy(fixture: fixture, includeChromiumData: true)
        let manager = makeManager(fixture: fixture, backupTriggerMode: .build)

        let first = try XCTUnwrap(try manager.prepareBackupIfNeeded(currentVersion: "2.0", currentBuild: 600))
        let second = try manager.prepareBackupIfNeeded(currentVersion: "2.0", currentBuild: 600)

        XCTAssertNil(second)
        let catalog = try TimeMachineCatalogStore(paths: fixture.paths).load()
        XCTAssertEqual(catalog.completedBackups.map(\.id), [first.id])
    }

    func testReleaseSnapshotDoesNotRecreateUserDeletedTrigger() throws {
        let fixture = try makeFixture(includePreferences: true)
        try writePolicy(fixture: fixture, includeChromiumData: true)
        let manager = makeManager(fixture: fixture, backupTriggerMode: .version)
        let store = TimeMachineCatalogStore(paths: fixture.paths)

        let first = try XCTUnwrap(try manager.prepareBackupIfNeeded(currentVersion: "2.0", currentBuild: 600))
        XCTAssertEqual(try store.deleteBackupAtUserRequest(id: first.id), first)

        let second = try manager.prepareBackupIfNeeded(currentVersion: "2.0", currentBuild: 601)

        XCTAssertNil(second)
        let catalog = try store.load()
        XCTAssertTrue(catalog.completedBackups.isEmpty)
        XCTAssertTrue(catalog.backups.isEmpty)
        XCTAssertEqual(catalog.suppressedBackupTriggers.count, 1)
    }

    func testSnapshotStoresRollbackAppBundleName() throws {
        let fixture = try makeFixture(includePreferences: true)
        try writePolicy(
            fixture: fixture,
            includeChromiumData: true,
            rollbackAppBundleName: "Phi Canary.app"
        )
        let manager = makeManager(fixture: fixture)

        let record = try XCTUnwrap(try manager.prepareBackupIfNeeded(currentVersion: "2.0", currentBuild: 600))

        let snapshotURL = fixture.paths.url(forRelativePath: record.snapshotRelativePath)
        let manifest = try readManifest(from: snapshotURL)
        XCTAssertEqual(record.rollbackAppBundleName, "Phi Canary.app")
        XCTAssertEqual(manifest.rollbackAppBundleName, "Phi Canary.app")
    }

    func testFailedSnapshotLeavesNoCompletedCatalogEntry() throws {
        let fixture = try makeFixture(includePreferences: true)
        try FileManager.default.removeItem(at: fixture.applicationSupportURL)
        try writePolicy(fixture: fixture, includeChromiumData: true)
        let manager = makeManager(fixture: fixture)

        XCTAssertThrowsError(try manager.prepareBackupIfNeeded(currentVersion: "2.0", currentBuild: 600))
        XCTAssertTrue(try TimeMachineCatalogStore(paths: fixture.paths).load().completedBackups.isEmpty)
    }

    func testSnapshotReportsBackupSizeAndDuration() throws {
        let fixture = try makeFixture(includePreferences: true)
        try writePolicy(fixture: fixture, includeChromiumData: true)
        let uptime = UptimeSequence([10, 12.5])
        var traces: [TimeMachineBackupTrace] = []
        let manager = makeManager(
            fixture: fixture,
            uptimeProvider: uptime.next,
            backupTraceReporter: { traces.append($0) }
        )

        let record = try XCTUnwrap(try manager.prepareBackupIfNeeded(currentVersion: "2.0", currentBuild: 600))

        let snapshotURL = fixture.paths.url(forRelativePath: record.snapshotRelativePath)
        let storedRecord = try XCTUnwrap(
            TimeMachineCatalogStore(paths: fixture.paths).load().completedBackups.first
        )
        let trace = try XCTUnwrap(traces.first)
        XCTAssertEqual(traces.count, 1)
        XCTAssertEqual(trace.result, .succeeded)
        XCTAssertEqual(trace.backupID, record.id)
        XCTAssertEqual(trace.bundleIdentifier, "com.phibrowser.Mac")
        XCTAssertEqual(trace.duration, 2.5)
        XCTAssertEqual(trace.snapshotSizeBytes, TimeMachineFileMetrics.sizeBytes(at: snapshotURL))
        XCTAssertEqual(record.snapshotSizeBytes, trace.snapshotSizeBytes)
        XCTAssertEqual(storedRecord.snapshotSizeBytes, trace.snapshotSizeBytes)
        XCTAssertGreaterThan(trace.snapshotSizeBytes ?? 0, 0)
    }

    func testSnapshotRemainsCommittedWhenSizeMetadataUpdateFails() throws {
        let fixture = try makeFixture(includePreferences: true)
        try writePolicy(fixture: fixture, includeChromiumData: true)
        var writeCount = 0
        let store = TimeMachineCatalogStore(
            paths: fixture.paths,
            catalogWriter: { data, catalogURL in
                writeCount += 1
                if writeCount == 2 {
                    throw TimeMachineSnapshotTestError.sizeMetadataWriteFailed
                }
                try data.write(to: catalogURL, options: .atomic)
            }
        )
        let manager = makeManager(fixture: fixture, catalogStore: store)

        let record = try XCTUnwrap(
            try manager.prepareBackupIfNeeded(currentVersion: "2.0", currentBuild: 600)
        )

        XCTAssertNil(record.snapshotSizeBytes)
        XCTAssertTrue(fileExists(fixture.paths.url(forRelativePath: record.snapshotRelativePath)))
        let storedRecord = try XCTUnwrap(try store.load().completedBackups.first)
        XCTAssertEqual(storedRecord.id, record.id)
        XCTAssertNil(storedRecord.snapshotSizeBytes)
    }

    private struct Fixture {
        let rootURL: URL
        let paths: TimeMachinePaths
        let policyURL: URL
        let applicationSupportURL: URL
        let phiDataURL: URL
        let preferencesURL: URL
    }

    private func makeFixture(includePreferences: Bool) throws -> Fixture {
        let rootURL = try makeTemporaryDirectory()
        let paths = TimeMachinePaths(rootURL: rootURL.appendingPathComponent("TimeMachine", isDirectory: true), bundleIdentifier: "com.phibrowser.Mac")
        let sourceRoot = rootURL.appendingPathComponent("Source", isDirectory: true)
        let appSupportURL = sourceRoot.appendingPathComponent("Application Support/com.phibrowser.Mac", isDirectory: true)
        let phiDataURL = appSupportURL.appendingPathComponent("Phi", isDirectory: true)
        let chromiumURL = appSupportURL.appendingPathComponent("Default", isDirectory: true)
        let preferencesURL = sourceRoot.appendingPathComponent("Preferences/com.phibrowser.Mac.plist", isDirectory: false)
        let policyURL = rootURL.appendingPathComponent("TimeMachineRollbackPolicy.json", isDirectory: false)

        try FileManager.default.createDirectory(at: phiDataURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: chromiumURL, withIntermediateDirectories: true)
        try "phi".write(to: phiDataURL.appendingPathComponent("local.txt"), atomically: true, encoding: .utf8)
        try "chromium".write(to: chromiumURL.appendingPathComponent("chrome.txt"), atomically: true, encoding: .utf8)

        if includePreferences {
            try FileManager.default.createDirectory(at: preferencesURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "plist".write(to: preferencesURL, atomically: true, encoding: .utf8)
        }

        return Fixture(
            rootURL: rootURL,
            paths: paths,
            policyURL: policyURL,
            applicationSupportURL: appSupportURL,
            phiDataURL: phiDataURL,
            preferencesURL: preferencesURL
        )
    }

    private func writePolicy(
        fixture: Fixture,
        includeChromiumData: Bool,
        rollbackAppBundleName: String? = nil
    ) throws {
        var policy: [String: Any] = [
            "backupTriggerBuild": 600,
            "backupTriggerVersion": "2.0",
            "rollbackVersion": "1.6",
            "rollbackBuild": 590,
            "rollbackPackageURL": "https://example.com/Phi-1.6-590.zip",
            "rollbackPackageSHA256": "abc123",
            "includeChromiumData": includeChromiumData
        ]
        if let rollbackAppBundleName {
            policy["rollbackAppBundleName"] = rollbackAppBundleName
        }
        let data = try JSONSerialization.data(withJSONObject: policy, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: fixture.policyURL)
    }

    private func makeManager(
        fixture: Fixture,
        backupTriggerMode: TimeMachineBackupTriggerMode = .current,
        catalogStore: TimeMachineCatalogStore? = nil,
        uptimeProvider: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        backupTraceReporter: @escaping TimeMachineSnapshotManager.BackupTraceReporter = { _ in }
    ) -> TimeMachineSnapshotManager {
        TimeMachineSnapshotManager(
            paths: fixture.paths,
            policyLoader: TimeMachineRollbackPolicyLoader(policyURLProvider: { fixture.policyURL }),
            backupTriggerMode: backupTriggerMode,
            catalogStore: catalogStore ?? TimeMachineCatalogStore(paths: fixture.paths),
            applicationSupportURLProvider: { fixture.applicationSupportURL },
            phiDataURLProvider: { fixture.phiDataURL },
            preferencesURLProvider: { fixture.preferencesURL },
            dateProvider: { Date(timeIntervalSince1970: 1_781_020_800) },
            uptimeProvider: uptimeProvider,
            idProvider: { UUID(uuidString: "00000000-0000-0000-0000-000000000700")! },
            fileCloner: TimeMachineFileCloner(),
            backupTraceReporter: backupTraceReporter
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: "/Users/Shared", isDirectory: true)
            .appendingPathComponent("TimeMachineSnapshotTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryDirectories.append(url)
        return url
    }

    private func fileExists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    private func readManifest(from snapshotURL: URL) throws -> TimeMachineSnapshotManifest {
        let data = try Data(contentsOf: snapshotURL.appendingPathComponent(TimeMachineSnapshotManifest.filename))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(TimeMachineSnapshotManifest.self, from: data)
    }
}

private enum TimeMachineSnapshotTestError: Error {
    case sizeMetadataWriteFailed
}

private final class UptimeSequence {
    private var values: [TimeInterval]

    init(_ values: [TimeInterval]) {
        self.values = values
    }

    func next() -> TimeInterval {
        values.removeFirst()
    }
}

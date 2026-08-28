// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

final class TimeMachineMenuPresenterTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
    }

    func testEmptyCatalogBuildsDisabledPlaceholder() throws {
        let fixture = try makeFixture()
        let presenter = TimeMachineMenuPresenter(
            catalogStore: TimeMachineCatalogStore(paths: fixture.paths),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )

        let entries = try presenter.menuEntries()

        XCTAssertEqual(entries, [
            TimeMachineMenuEntry(
                title: TimeMachineMenuPresenter.emptyTitle,
                backupID: nil,
                isEnabled: false
            )
        ])
    }

    func testCompletedBackupsUseRollbackVersionBuildAndDate() throws {
        let fixture = try makeFixture()
        let record = try makeBackup(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000001001")!,
            createdAt: makeDate(year: 2026, month: 6, day: 11),
            rollbackVersion: "1.6.0"
        )
        try TimeMachineCatalogStore(paths: fixture.paths).save(TimeMachineCatalog(backups: [record]))
        let presenter = TimeMachineMenuPresenter(
            catalogStore: TimeMachineCatalogStore(paths: fixture.paths),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )

        let entries = try presenter.menuEntries()

        XCTAssertEqual(entries, [
            TimeMachineMenuEntry(
                title: "Phi 1.6.0 (590) on 2026.6.11",
                backupID: record.id,
                isEnabled: true
            )
        ])
    }

    func testCompletedCanaryBackupsUseCanaryLabel() throws {
        let fixture = try makeFixture()
        let record = try makeBackup(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000001005")!,
            createdAt: makeDate(year: 2026, month: 6, day: 11),
            rollbackVersion: "Canary"
        )
        try TimeMachineCatalogStore(paths: fixture.paths).save(TimeMachineCatalog(backups: [record]))
        let presenter = TimeMachineMenuPresenter(
            catalogStore: TimeMachineCatalogStore(paths: fixture.paths),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )

        let entries = try presenter.menuEntries()

        XCTAssertEqual(entries, [
            TimeMachineMenuEntry(
                title: "Phi Canary (590) on 2026.6.11",
                backupID: record.id,
                isEnabled: true
            )
        ])
    }

    func testBackupLookupMapsSelectedIDToRecord() throws {
        let fixture = try makeFixture()
        let selected = try makeBackup(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000001002")!,
            createdAt: makeDate(year: 2026, month: 6, day: 11)
        )
        let older = try makeBackup(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000001003")!,
            createdAt: makeDate(year: 2026, month: 6, day: 10)
        )
        try TimeMachineCatalogStore(paths: fixture.paths).save(TimeMachineCatalog(backups: [older, selected]))
        let presenter = TimeMachineMenuPresenter(
            catalogStore: TimeMachineCatalogStore(paths: fixture.paths),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )

        XCTAssertEqual(try presenter.backup(id: selected.id), selected)
        XCTAssertNil(try presenter.backup(id: UUID(uuidString: "00000000-0000-0000-0000-000000001004")!))
    }

    func testBackupDetailsUsesStoredSnapshotSize() throws {
        let fixture = try makeFixture()
        let record = try makeBackup(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000001006")!,
            createdAt: makeDate(year: 2026, month: 6, day: 11),
            snapshotSizeBytes: 1_234
        )
        try FileManager.default.createDirectory(
            at: fixture.paths.url(forRelativePath: record.snapshotRelativePath),
            withIntermediateDirectories: true
        )
        try TimeMachineCatalogStore(paths: fixture.paths).save(TimeMachineCatalog(backups: [record]))
        let presenter = TimeMachineMenuPresenter(
            catalogStore: TimeMachineCatalogStore(paths: fixture.paths),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )

        let details = try XCTUnwrap(try presenter.backupDetails(id: record.id))

        XCTAssertEqual(details.backup, record)
        XCTAssertEqual(details.snapshotSizeBytes, 1_234)
    }

    func testBackupDetailsReturnsLegacyRecordBeforeBackgroundSizeResolution() throws {
        let fixture = try makeFixture()
        let record = try makeBackup(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000001007")!,
            createdAt: makeDate(year: 2026, month: 6, day: 11)
        )
        let snapshotURL = fixture.paths.url(forRelativePath: record.snapshotRelativePath)
        try FileManager.default.createDirectory(at: snapshotURL, withIntermediateDirectories: true)
        try Data(repeating: 0x1, count: 2_048).write(to: snapshotURL.appendingPathComponent("data.bin"))
        try TimeMachineCatalogStore(paths: fixture.paths).save(TimeMachineCatalog(backups: [record]))
        let presenter = TimeMachineMenuPresenter(
            catalogStore: TimeMachineCatalogStore(paths: fixture.paths),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )

        let details = try XCTUnwrap(try presenter.backupDetails(id: record.id))

        XCTAssertNil(details.snapshotSizeBytes)
    }

    private struct Fixture {
        let rootURL: URL
        let paths: TimeMachinePaths
    }

    private func makeFixture() throws -> Fixture {
        let rootURL = try makeTemporaryDirectory()
        return Fixture(
            rootURL: rootURL,
            paths: TimeMachinePaths(
                rootURL: rootURL.appendingPathComponent("TimeMachine", isDirectory: true),
                bundleIdentifier: "com.phibrowser.Mac"
            )
        )
    }

    private func makeBackup(
        id: UUID,
        createdAt: Date,
        rollbackVersion: String = "1.6.0",
        snapshotSizeBytes: UInt64? = nil
    ) throws -> TimeMachineBackupRecord {
        TimeMachineBackupRecord(
            id: id,
            createdAt: createdAt,
            creatingVersion: "2.0",
            creatingBuild: 600,
            backupTriggerBuild: 600,
            rollbackVersion: rollbackVersion,
            rollbackBuild: 590,
            rollbackPackageURL: try XCTUnwrap(URL(string: "https://example.com/Phi-1.6-590.zip")),
            rollbackPackageSHA256: "abc123",
            includeChromiumData: true,
            snapshotRelativePath: "Snapshots/\(id.uuidString)",
            snapshotSizeBytes: snapshotSizeBytes,
            status: .completed
        )
    }

    private func makeDate(year: Int, month: Int, day: Int) throws -> Date {
        try XCTUnwrap(DateComponents(
            calendar: Calendar(identifier: .gregorian),
            timeZone: TimeZone(secondsFromGMT: 0),
            year: year,
            month: month,
            day: day,
            hour: 9
        ).date)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: "/Users/Shared", isDirectory: true)
            .appendingPathComponent("TimeMachineMenuPresenterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryDirectories.append(url)
        return url
    }
}

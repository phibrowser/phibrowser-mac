// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

final class TelemetryPrivacyTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
    }

    func testMetricsReportingSnapshotDefaultsToDeniedAndClearsIdentityWhenDisabled() {
        let coordinator = PhiChromiumCoordinator()

        XCTAssertFalse(coordinator.metricsReportingEnabledSnapshot)
        XCTAssertNil(coordinator.metricsReportingSnapshot.clientID)

        coordinator.updateMetricsReportingSnapshot(isEnabled: true, clientID: "client-id")

        XCTAssertTrue(coordinator.metricsReportingEnabledSnapshot)
        XCTAssertEqual(coordinator.metricsReportingSnapshot.clientID, "client-id")

        coordinator.updateMetricsReportingSnapshot(isEnabled: false, clientID: "must-not-persist")

        XCTAssertFalse(coordinator.metricsReportingEnabledSnapshot)
        XCTAssertNil(coordinator.metricsReportingSnapshot.clientID)
    }

    func testSentryCachePurgeRemovesOnlyTelemetryState() throws {
        let root = try makeTemporaryDirectory()
        let sentryDirectory = root.appendingPathComponent("io.sentry", isDirectory: true)
        let installationFile = root.appendingPathComponent("INSTALLATION", isDirectory: false)
        let unrelatedFile = root.appendingPathComponent("account.json", isDirectory: false)
        try FileManager.default.createDirectory(at: sentryDirectory, withIntermediateDirectories: true)
        try Data("envelope".utf8).write(
            to: sentryDirectory.appendingPathComponent("queued-envelope.json")
        )
        try Data("installation-id".utf8).write(to: installationFile)
        try Data("keep".utf8).write(to: unrelatedFile)

        try SentryService.purgeCachedTelemetry(at: root)

        XCTAssertFalse(FileManager.default.fileExists(atPath: sentryDirectory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: installationFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelatedFile.path))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TelemetryPrivacyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryDirectories.append(url)
        return url
    }
}

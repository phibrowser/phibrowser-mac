// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

final class AIDataExportCoordinatorTests: XCTestCase {
    private func makeTempFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai-data-\(UUID().uuidString).tar.gz", isDirectory: false)
        try Data("tar".utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testSentinelUnavailableDegradesToBrowserOnly() async throws {
        let tarURL = try makeTempFile()
        let coordinator = AIDataExportCoordinator(
            ensureSentinelRunning: { false },
            requestExport: { _ in XCTFail("should not request export"); return .timedOut },
            fileExists: { _ in true },
            isCancelled: { false }
        )
        let result = await coordinator.coordinate(destinationTarURL: tarURL)
        XCTAssertEqual(result, .skippedBrowserOnly(reason: .sentinelUnavailable))
    }

    func testTimeoutDegradesToBrowserOnly() async throws {
        let tarURL = try makeTempFile()
        let coordinator = AIDataExportCoordinator(
            ensureSentinelRunning: { true },
            requestExport: { _ in .timedOut },
            fileExists: { _ in true },
            isCancelled: { false }
        )
        let result = await coordinator.coordinate(destinationTarURL: tarURL)
        XCTAssertEqual(result, .skippedBrowserOnly(reason: .timedOut))
    }

    func testSentinelErrorStatusDegradesToBrowserOnly() async throws {
        let tarURL = try makeTempFile()
        let coordinator = AIDataExportCoordinator(
            ensureSentinelRunning: { true },
            requestExport: { _ in .response(.init(status: .error, path: nil, error: "boom")) },
            fileExists: { _ in true },
            isCancelled: { false }
        )
        let result = await coordinator.coordinate(destinationTarURL: tarURL)
        XCTAssertEqual(result, .skippedBrowserOnly(reason: .exportFailed))
    }

    func testCompletedButMissingFileDegradesToBrowserOnly() async throws {
        let tarURL = try makeTempFile()
        let coordinator = AIDataExportCoordinator(
            ensureSentinelRunning: { true },
            requestExport: { path in .response(.init(status: .completed, path: path, error: nil)) },
            fileExists: { _ in false },
            isCancelled: { false }
        )
        let result = await coordinator.coordinate(destinationTarURL: tarURL)
        XCTAssertEqual(result, .skippedBrowserOnly(reason: .exportFailed))
    }

    func testCancelBeforeRequestDegradesToBrowserOnly() async throws {
        let tarURL = try makeTempFile()
        let coordinator = AIDataExportCoordinator(
            ensureSentinelRunning: { true },
            requestExport: { _ in XCTFail("should not request export"); return .timedOut },
            fileExists: { _ in true },
            isCancelled: { true }
        )
        let result = await coordinator.coordinate(destinationTarURL: tarURL)
        XCTAssertEqual(result, .skippedBrowserOnly(reason: .cancelled))
    }

    func testCompletedWithFilePacks() async throws {
        let tarURL = try makeTempFile()
        let coordinator = AIDataExportCoordinator(
            ensureSentinelRunning: { true },
            requestExport: { path in .response(.init(status: .completed, path: path, error: nil)) },
            fileExists: { _ in true },
            isCancelled: { false }
        )
        let result = await coordinator.coordinate(destinationTarURL: tarURL)
        XCTAssertEqual(result, .packed(tarURL: tarURL))
    }
}

extension AIDataExportCoordinatorTests {
    func testAppendAIDataArchiveStoresTarAtZipRootNextToPhi() throws {
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai-export-pack-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: workDir) }

        // Build a base zip that already contains Phi/ (mirror zipPhiBrowserDataDirectory).
        let phiDir = workDir.appendingPathComponent("Phi", isDirectory: true)
        try FileManager.default.createDirectory(at: phiDir, withIntermediateDirectories: true)
        try Data("data".utf8).write(to: phiDir.appendingPathComponent("localdb"))
        let zipURL = workDir.appendingPathComponent("backup.zip", isDirectory: false)
        let makeZip = Process()
        makeZip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        makeZip.arguments = ["-r", "-q", zipURL.path, "Phi"]
        makeZip.currentDirectoryURL = workDir
        try makeZip.run(); makeZip.waitUntilExit()
        XCTAssertEqual(makeZip.terminationStatus, 0)

        // The tar sits in its own temp dir.
        let tarDir = workDir.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: tarDir, withIntermediateDirectories: true)
        let tarURL = tarDir.appendingPathComponent("ai-data.tar.gz", isDirectory: false)
        try Data("tarball".utf8).write(to: tarURL)

        try AppController.appendAIDataArchive(tarURL, to: zipURL)

        // Assert the zip now lists both Phi/ and ai-data.tar.gz at the root.
        let list = Process()
        let pipe = Pipe()
        list.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        list.arguments = ["-Z", "-1", zipURL.path]
        list.standardOutput = pipe
        try list.run(); list.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let entries = Set(output.split(separator: "\n").map(String.init))
        XCTAssertTrue(entries.contains("ai-data.tar.gz"), "Expected ai-data.tar.gz at zip root, got \(entries)")
        XCTAssertTrue(entries.contains { $0.hasPrefix("Phi/") }, "Expected Phi/ entries preserved, got \(entries)")
    }
}

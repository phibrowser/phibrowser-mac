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

// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import XCTest
@testable import Phi

final class PhiUserDataExportTests: XCTestCase {
    func testSelectionRequiresAtLeastOneCategory() {
        XCTAssertFalse(PhiUserDataExportSelection(
            includeBrowserData: false,
            includeAIData: false
        ).isExportable)
        XCTAssertTrue(PhiUserDataExportSelection(
            includeBrowserData: true,
            includeAIData: false
        ).isExportable)
        XCTAssertTrue(PhiUserDataExportSelection(
            includeBrowserData: false,
            includeAIData: true
        ).isExportable)
    }

    func testSentinelExportSessionUsesScopedCanonicalPath() throws {
        let root = makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let requestID = UUID()

        let session = try SentinelAIDataExportSession.prepare(
            sharedContainerURL: root,
            sentinelBundleID: "com.phibrowser.canary.Sentinel",
            requestID: requestID
        )

        XCTAssertEqual(session.requestID, requestID)
        XCTAssertEqual(
            session.archiveURL,
            root
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Caches", isDirectory: true)
                .appendingPathComponent("SentinelExports", isDirectory: true)
                .appendingPathComponent("com.phibrowser.canary.Sentinel", isDirectory: true)
                .appendingPathComponent(requestID.uuidString, isDirectory: true)
                .appendingPathComponent("ai-data.tar.gz")
        )
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: session.directoryURL.path,
            isDirectory: &isDirectory
        ))
        XCTAssertTrue(isDirectory.boolValue)
    }

    func testLateWriteOutcomesRetainSessionForExpirationCleanup() {
        XCTAssertTrue(
            AIDataExportCoordinator.SkipReason.timedOut
                .shouldRetainSessionForLateWrite
        )
        XCTAssertTrue(
            AIDataExportCoordinator.SkipReason.invalidResponsePath
                .shouldRetainSessionForLateWrite
        )
        XCTAssertTrue(
            AIDataExportCoordinator.SkipReason.cancelled
                .shouldRetainSessionForLateWrite
        )
        XCTAssertFalse(
            AIDataExportCoordinator.SkipReason.sentinelUnavailable
                .shouldRetainSessionForLateWrite
        )
        XCTAssertFalse(
            AIDataExportCoordinator.SkipReason.exportFailed
                .shouldRetainSessionForLateWrite
        )
    }

    func testPreparingSessionRemovesExpiredSibling() throws {
        let root = makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let now = Date(timeIntervalSince1970: 2_000_000)
        let expired = try SentinelAIDataExportSession.prepare(
            sharedContainerURL: root,
            sentinelBundleID: "com.phibrowser.Sentinel",
            requestID: UUID(),
            now: now
        )
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-25 * 60 * 60)],
            ofItemAtPath: expired.directoryURL.path
        )

        _ = try SentinelAIDataExportSession.prepare(
            sharedContainerURL: root,
            sentinelBundleID: "com.phibrowser.Sentinel",
            requestID: UUID(),
            now: now
        )

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: expired.directoryURL.path
        ))
    }

    func testAppendAIDataArchiveUsesCanonicalRootEntryName() throws {
        let root = makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let source = root.appendingPathComponent("sentinel-export.tar.gz")
        let destination = root.appendingPathComponent("backup.zip")
        try Data("AI backup".utf8).write(to: source)

        try AppController.appendAIDataArchive(source, to: destination)

        XCTAssertEqual(
            try zipEntries(in: destination),
            ["ai-data.tar.gz"]
        )
    }

    func testAppendAIDataArchivePreservesExistingBrowserRoot() throws {
        let root = makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let phiDirectory = root.appendingPathComponent("Phi", isDirectory: true)
        try FileManager.default.createDirectory(
            at: phiDirectory,
            withIntermediateDirectories: false
        )
        try Data("browser".utf8).write(
            to: phiDirectory.appendingPathComponent("state.json")
        )
        let destination = root.appendingPathComponent("backup.zip")
        try run(
            executable: "/usr/bin/zip",
            arguments: ["-r", "-q", destination.path, "Phi"],
            currentDirectory: root
        )

        let aiArchive = root.appendingPathComponent("ai-data.tar.gz")
        try Data("AI backup".utf8).write(to: aiArchive)
        try AppController.appendAIDataArchive(aiArchive, to: destination)

        XCTAssertEqual(
            Set(try zipEntries(in: destination)),
            Set(["Phi/", "Phi/state.json", "ai-data.tar.gz"])
        )
    }

    func testAppendAIDataArchiveRejectsSymbolicLink() throws {
        let root = makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let archiveTarget = root.appendingPathComponent("target.tar.gz")
        let archiveLink = root.appendingPathComponent("ai-data.tar.gz")
        let destination = root.appendingPathComponent("backup.zip")
        try Data("not Sentinel output".utf8).write(to: archiveTarget)
        try FileManager.default.createSymbolicLink(
            at: archiveLink,
            withDestinationURL: archiveTarget
        )

        XCTAssertThrowsError(
            try AppController.appendAIDataArchive(
                archiveLink,
                to: destination
            )
        )
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: destination.path
        ))
    }

    private func makeTemporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PhiUserDataExportTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try! FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: false
        )
        return url
    }

    private func zipEntries(in archive: URL) throws -> [String] {
        let output = try run(
            executable: "/usr/bin/unzip",
            arguments: ["-Z1", archive.path]
        )
        return output
            .split(whereSeparator: \.isNewline)
            .map(String.init)
    }

    @discardableResult
    private func run(
        executable: String,
        arguments: [String],
        currentDirectory: URL? = nil
    ) throws -> String {
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            throw NSError(
                domain: "PhiUserDataExportTests",
                code: Int(process.terminationStatus),
                userInfo: [
                    NSLocalizedDescriptionKey: String(
                        data: errorData,
                        encoding: .utf8
                    ) ?? "Command failed"
                ]
            )
        }
        return String(data: outputData, encoding: .utf8) ?? ""
    }
}

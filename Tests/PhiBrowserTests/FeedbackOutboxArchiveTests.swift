// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Security
import XCTest
@testable import Phi

final class FeedbackOutboxArchiveTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FeedbackOutboxArchiveTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
        root = nil
        try super.tearDownWithError()
    }

    func testBucketArchiveItemsUsesOriginalByteCounts() {
        let halfBucket = UInt64(FeedbackOutbox.zipPlanningBytes / 2)
        let items = [
            archiveItem(path: "PhiLogs/a.log", plannedBytes: halfBucket),
            archiveItem(path: "PhiLogs/b.log", plannedBytes: halfBucket),
            archiveItem(path: "SentinelLogs/c.log", plannedBytes: 1)
        ]

        let buckets = FeedbackOutbox.bucketArchiveItems(items)

        XCTAssertEqual(buckets.map { $0.map(\.archivePath) }, [
            ["PhiLogs/a.log", "PhiLogs/b.log"],
            ["SentinelLogs/c.log"]
        ])
        XCTAssertTrue(buckets.allSatisfy { bucket in
            let total = bucket.reduce(Int64(0)) { $0 + Int64($1.length) }
            return total <= FeedbackOutbox.zipPlanningBytes
        })
    }

    func testCrashSnapshotSurvivesLogRotationAndArchiveRetry() throws {
        let log = root.appendingPathComponent("current.log")
        try Data("before crash".utf8).write(to: log)
        let context = PreviousSessionCrashContext(
            eventID: "crash-event", timestamp: nil,
            logSnapshot: PhiLogging.logSnapshot(paths: [log.path], maxBytes: 1024)
        )
        let jobRoot = try makeJobDirectory()
        let saved = try XCTUnwrap(FeedbackOutbox.savePreviousSessionCrashLog(context, jobRoot: jobRoot))
        try Data("after relaunch".utf8).write(to: log)
        let preparedDir = try makePreparedDirectory(in: jobRoot)
        for _ in 0..<2 {
            let attachments = try FeedbackOutbox.prepareLogZipAttachments(
                jobRoot: jobRoot, preparedDir: preparedDir, chromiumSystemLogs: nil,
                previousSessionCrashLog: saved,
                phiLogsURL: root.appendingPathComponent("missing-phi"),
                sentinelLogsURL: root.appendingPathComponent("missing-sentinel")
            )
            let archive = try XCTUnwrap(attachments.first { $0.filename == "logs.zip" })
            XCTAssertEqual(
                try zipEntryText("PreviousSessionCrash/logs.txt", in: jobRoot.appendingPathComponent(archive.relativePath)),
                "before crash"
            )
            try FileManager.default.removeItem(at: jobRoot.appendingPathComponent(archive.relativePath))
        }
    }

    func testMissingQueuedCrashSnapshotFailsInsteadOfSendingOnlyCurrentLogs() throws {
        let jobRoot = try makeJobDirectory()
        let preparedDir = try makePreparedDirectory(in: jobRoot)
        let missing = FeedbackOutboxSourceAttachment(
            relativePath: "logs/missing.log", filename: "missing.log", mimeType: "text/plain", size: 10
        )
        XCTAssertThrowsError(try FeedbackOutbox.prepareLogZipAttachments(
            jobRoot: jobRoot, preparedDir: preparedDir, chromiumSystemLogs: nil,
            previousSessionCrashLog: missing,
            phiLogsURL: root.appendingPathComponent("missing-phi"),
            sentinelLogsURL: root.appendingPathComponent("missing-sentinel")
        ))
    }

    func testCollectLogArchiveItemsSplitsOversizedLogFiles() throws {
        let logsRoot = root.appendingPathComponent("PhiLogs", isDirectory: true)
        try FileManager.default.createDirectory(at: logsRoot, withIntermediateDirectories: true)
        try Data("small".utf8).write(to: logsRoot.appendingPathComponent("small.log"))

        let largeLog = logsRoot.appendingPathComponent("large.log")
        FileManager.default.createFile(atPath: largeLog.path, contents: nil)
        let handle = try FileHandle(forWritingTo: largeLog)
        try handle.truncate(atOffset: UInt64(FeedbackOutbox.zipPlanningBytes + 1024))
        try handle.close()

        let items = try FeedbackOutbox.collectLogArchiveItems(root: logsRoot, archiveRoot: "PhiLogs")
        let largeParts = items.filter { $0.archivePath.hasPrefix("PhiLogs/large.log.part-") }

        XCTAssertEqual(largeParts.count, 2)
        XCTAssertEqual(largeParts[0].archivePath, "PhiLogs/large.log.part-1")
        XCTAssertEqual(largeParts[0].offset, 0)
        XCTAssertEqual(largeParts[0].length, UInt64(FeedbackOutbox.zipPlanningBytes))
        XCTAssertEqual(largeParts[1].archivePath, "PhiLogs/large.log.part-2")
        XCTAssertEqual(largeParts[1].offset, UInt64(FeedbackOutbox.zipPlanningBytes))
        XCTAssertEqual(largeParts[1].length, 1024)
    }

    func testSelectedAttachmentInfoAcceptsRegularFilesUnderLimit() throws {
        let fileURL = root.appendingPathComponent("note.txt")
        try Data("hello".utf8).write(to: fileURL)

        let info = try FeedbackOutbox.selectedAttachmentInfo(for: fileURL)

        XCTAssertEqual(info.size, 5)
        XCTAssertFalse(info.isImage)
        XCTAssertEqual(info.mimeType, "text/plain")
    }

    func testSelectedAttachmentInfoRejectsDirectories() throws {
        let directoryURL = root.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        XCTAssertThrowsError(try FeedbackOutbox.selectedAttachmentInfo(for: directoryURL))
    }

    func testSelectedAttachmentInfoRejectsSymlinks() throws {
        let targetURL = root.appendingPathComponent("target.txt")
        let linkURL = root.appendingPathComponent("target-link.txt")
        try Data("hello".utf8).write(to: targetURL)
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: targetURL)

        XCTAssertThrowsError(try FeedbackOutbox.selectedAttachmentInfo(for: linkURL))
    }

    func testSelectedAttachmentInfoRejectsFilesOverTenMegabytes() throws {
        let fileURL = root.appendingPathComponent("large.bin")
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.truncate(atOffset: UInt64(FeedbackOutbox.maxSelectedAttachmentBytes + 1))
        try handle.close()

        XCTAssertThrowsError(try FeedbackOutbox.selectedAttachmentInfo(for: fileURL))
    }

    func testBrowserChannelNameMapsNightlyBuildToCanary() {
        XCTAssertEqual(
            FeedbackOutbox.browserChannelName(isNightlyBuild: true, isDebugBuild: false),
            "canary"
        )
    }

    func testBrowserChannelNamePrefersNightlyOverDebug() {
        XCTAssertEqual(
            FeedbackOutbox.browserChannelName(isNightlyBuild: true, isDebugBuild: true),
            "canary"
        )
    }

    func testBrowserChannelNameMapsDebugBuildToDebug() {
        XCTAssertEqual(
            FeedbackOutbox.browserChannelName(isNightlyBuild: false, isDebugBuild: true),
            "debug"
        )
    }

    func testBrowserChannelNameDefaultsToStable() {
        XCTAssertEqual(
            FeedbackOutbox.browserChannelName(isNightlyBuild: false, isDebugBuild: false),
            "stable"
        )
    }

    func testFeedbackComponentsIncludeRunningSentinelVersion() {
        let components = FeedbackOutbox.feedbackComponents(
            extensionVersions: ["phi-sidecar": "2.0.0"],
            runningSentinelInfo: SentinelHelper.RunningInfo(
                bundleID: "com.phibrowser.Sentinel",
                version: "1.3.3",
                build: "414"
            )
        )

        let sentinel = components.first { $0.id == "com.phibrowser.Sentinel" }
        XCTAssertEqual(sentinel?.name, "Phi Sentinel")
        XCTAssertEqual(sentinel?.type, "component")
        XCTAssertEqual(sentinel?.version, "1.3.3")
        XCTAssertEqual(components.first { $0.id == "phi-sidecar" }?.type, "extension")
    }

    func testFeedbackComponentsSkipSentinelWithoutVersion() {
        let components = FeedbackOutbox.feedbackComponents(
            extensionVersions: ["phi-sidecar": "2.0.0"],
            runningSentinelInfo: SentinelHelper.RunningInfo(
                bundleID: "com.phibrowser.Sentinel",
                version: " ",
                build: "414"
            )
        )

        XCTAssertNil(components.first { $0.id == "com.phibrowser.Sentinel" })
        XCTAssertEqual(components.map(\.id), ["phi-sidecar"])
    }

    func testShouldDiscardFailedJobOnlyAfterFiveLargeRetries() {
        XCTAssertFalse(FeedbackOutbox.shouldDiscardFailedJob(retryCount: 5))
        XCTAssertTrue(FeedbackOutbox.shouldDiscardFailedJob(retryCount: 6))
    }

    func testMakeZipAttachmentsUsesLogsZipForSingleBucket() throws {
        let preparedDir = try makePreparedDirectory()
        let items = [
            archiveItem(path: "PhiLogs/a.log", inlineText: "phi"),
            archiveItem(path: "SentinelLogs/b.log", inlineText: "sentinel")
        ]

        let attachments = try FeedbackOutbox.makeZipAttachments(
            items: items,
            preparedDir: preparedDir,
            singleFilename: "logs.zip",
            numberedPrefix: "logs",
            attachmentType: .log,
            required: true
        )

        XCTAssertEqual(attachments.count, 1)
        XCTAssertEqual(attachments[0].filename, "logs.zip")
        XCTAssertEqual(attachments[0].mimeType, "application/zip")
        XCTAssertEqual(attachments[0].attachmentType, .log)
        XCTAssertTrue(attachments[0].required)
        XCTAssertGreaterThan(attachments[0].size, 0)
        XCTAssertLessThanOrEqual(attachments[0].size, FeedbackOutbox.maxAttachmentBytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(attachments[0].relativePath).path))
    }

    func testMakeZipAttachmentsIncludesChromiumSystemLogsAtRoot() throws {
        let preparedDir = try makePreparedDirectory()
        let systemLogsText = "chromium system logs\n"
        let systemLogsURL = root.appendingPathComponent("system_logs.txt")
        try Data(systemLogsText.utf8).write(to: systemLogsURL)

        let attachments = try FeedbackOutbox.makeZipAttachments(
            items: [
                FeedbackOutbox.chromiumSystemLogsArchiveItem(sourceURL: systemLogsURL),
                archiveItem(path: "PhiLogs/a.log", inlineText: "phi")
            ],
            preparedDir: preparedDir,
            singleFilename: "logs.zip",
            numberedPrefix: "logs",
            attachmentType: .log,
            required: true,
            preferSingleArchiveWhenPossible: true
        )

        XCTAssertEqual(attachments.map(\.filename), ["logs.zip"])
        let zipURL = root.appendingPathComponent(attachments[0].relativePath)
        XCTAssertEqual(try zipEntryText("system_logs.txt", in: zipURL), systemLogsText)
        XCTAssertEqual(try zipEntryText("PhiLogs/a.log", in: zipURL), "phi")
    }

    func testPrepareLogZipAttachmentsUsesTwoPrioritizedArchives() throws {
        let jobRoot = try makeJobDirectory()
        let preparedDir = try makePreparedDirectory(in: jobRoot)
        let logsDir = jobRoot.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)

        let systemLogsURL = logsDir.appendingPathComponent("system_logs.txt")
        try Data("chromium logs".utf8).write(to: systemLogsURL)
        let chromiumSystemLogs = FeedbackOutboxSourceAttachment(
            relativePath: "logs/system_logs.txt",
            filename: "system_logs.txt",
            mimeType: "text/plain",
            size: 13
        )

        let phiLogsURL = root.appendingPathComponent("PhiLogs", isDirectory: true)
        try FileManager.default.createDirectory(at: phiLogsURL, withIntermediateDirectories: true)
        let oldPhiURL = try writeLog("old phi", named: "old.log", in: phiLogsURL, modifiedAt: Date(timeIntervalSince1970: 100))
        let currentPhiURL = try writeLog("current phi", named: "current.log", in: phiLogsURL, modifiedAt: Date(timeIntervalSince1970: 200))

        let sentinelLogsURL = root.appendingPathComponent("SentinelLogs", isDirectory: true)
        try FileManager.default.createDirectory(at: sentinelLogsURL, withIntermediateDirectories: true)
        let olderBootURL = try writeLog("old boot", named: "boot.log", in: sentinelLogsURL, modifiedAt: Date(timeIntervalSince1970: 100))
        let latestBootURL = try writeLog("latest boot", named: "boot.log.1", in: sentinelLogsURL, modifiedAt: Date(timeIntervalSince1970: 300))
        let latestRunnerURL = try writeLog("latest runner", named: "runner.log", in: sentinelLogsURL, modifiedAt: Date(timeIntervalSince1970: 250))
        let oldRunnerURL = try writeLog("old runner", named: "runner.log.1", in: sentinelLogsURL, modifiedAt: Date(timeIntervalSince1970: 150))
        let latestGatewayURL = try writeLog("latest gateway", named: "ai-gateway.log", in: sentinelLogsURL, modifiedAt: Date(timeIntervalSince1970: 275))
        let ignoredURL = try writeLog("ignored", named: "extra.log", in: sentinelLogsURL, modifiedAt: Date(timeIntervalSince1970: 400))

        let attachments = try FeedbackOutbox.prepareLogZipAttachments(
            jobRoot: jobRoot,
            preparedDir: preparedDir,
            chromiumSystemLogs: chromiumSystemLogs,
            phiLogsURL: phiLogsURL,
            sentinelLogsURL: sentinelLogsURL
        )

        XCTAssertEqual(attachments.map(\.filename), ["logs.zip", "sentinel-logs.zip"])
        XCTAssertTrue(attachments.allSatisfy { $0.attachmentType == .log })
        XCTAssertTrue(attachments.allSatisfy(\.required))
        XCTAssertTrue(attachments.allSatisfy { $0.size <= FeedbackOutbox.maxAttachmentBytes })

        let primaryZipURL = jobRoot.appendingPathComponent(attachments[0].relativePath)
        XCTAssertEqual(try zipEntryText("system_logs.txt", in: primaryZipURL), "chromium logs")
        XCTAssertEqual(try zipEntryText("PhiLogs/current.log", in: primaryZipURL), "current phi")
        XCTAssertFalse(try zipEntryExists("PhiLogs/old.log", in: primaryZipURL))

        let sentinelZipURL = jobRoot.appendingPathComponent(attachments[1].relativePath)
        XCTAssertEqual(try zipEntryText("main/boot.log", in: sentinelZipURL), "old boot")
        XCTAssertEqual(try zipEntryText("main/runner.log", in: sentinelZipURL), "latest runner")
        XCTAssertEqual(try zipEntryText("main/ai-gateway.log", in: sentinelZipURL), "latest gateway")
        XCTAssertFalse(try zipEntryExists("main/boot.log.1", in: sentinelZipURL))
        XCTAssertFalse(try zipEntryExists("main/runner.log.1", in: sentinelZipURL))
        XCTAssertFalse(try zipEntryExists("main/extra.log", in: sentinelZipURL))

        XCTAssertTrue(FileManager.default.fileExists(atPath: oldPhiURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: currentPhiURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: olderBootURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: latestBootURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: latestRunnerURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldRunnerURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: latestGatewayURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: ignoredURL.path))
    }

    func testPrepareLogZipAttachmentsBoundsLargePrimaryLogInsteadOfDroppingIt() throws {
        let jobRoot = try makeJobDirectory()
        let preparedDir = try makePreparedDirectory(in: jobRoot)
        let phiLogsURL = root.appendingPathComponent("PhiLogs", isDirectory: true)
        let sentinelLogsURL = root.appendingPathComponent("SentinelLogs", isDirectory: true)
        try FileManager.default.createDirectory(at: phiLogsURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sentinelLogsURL, withIntermediateDirectories: true)

        let largePhiLogURL = phiLogsURL.appendingPathComponent("current.log")
        try randomData(byteCount: Int(FeedbackOutbox.maxAttachmentBytes + 1024 * 1024)).write(to: largePhiLogURL)
        _ = try writeLog("runner", named: "runner.log", in: sentinelLogsURL, modifiedAt: Date())

        let attachments = try FeedbackOutbox.prepareLogZipAttachments(
            jobRoot: jobRoot,
            preparedDir: preparedDir,
            chromiumSystemLogs: nil,
            phiLogsURL: phiLogsURL,
            sentinelLogsURL: sentinelLogsURL
        )

        XCTAssertEqual(attachments.map(\.filename), ["logs.zip", "sentinel-logs.zip"])
        XCTAssertTrue(attachments.allSatisfy { $0.size <= FeedbackOutbox.maxAttachmentBytes })
        XCTAssertTrue(FileManager.default.fileExists(atPath: jobRoot.appendingPathComponent(attachments[0].relativePath).path))
    }

    func testMakeZipAttachmentsPrefersSingleLogsZipWhenCompressedUnderLimit() throws {
        let preparedDir = try makePreparedDirectory()
        let items = [
            archiveItem(path: "PhiLogs/a.log", plannedBytes: UInt64(FeedbackOutbox.zipPlanningBytes)),
            archiveItem(path: "SentinelLogs/b.log", plannedBytes: 1)
        ]

        let attachments = try FeedbackOutbox.makeZipAttachments(
            items: items,
            preparedDir: preparedDir,
            singleFilename: "logs.zip",
            numberedPrefix: "logs",
            attachmentType: .log,
            required: true,
            preferSingleArchiveWhenPossible: true
        )

        XCTAssertEqual(attachments.map(\.filename), ["logs.zip"])
        XCTAssertEqual(attachments[0].attachmentType, .log)
        XCTAssertLessThanOrEqual(attachments[0].size, FeedbackOutbox.maxAttachmentBytes)
    }

    func testMakeZipAttachmentsSplitsLogsWhenSingleZipExceedsLimit() throws {
        let preparedDir = try makePreparedDirectory()
        let first = try randomData(byteCount: 11 * 1024 * 1024)
        let second = try randomData(byteCount: 11 * 1024 * 1024)
        let items = [
            ArchiveItem(
                sourceURL: nil,
                inlineData: first,
                offset: 0,
                length: UInt64(first.count),
                archivePath: "PhiLogs/random-a.log"
            ),
            ArchiveItem(
                sourceURL: nil,
                inlineData: second,
                offset: 0,
                length: UInt64(second.count),
                archivePath: "SentinelLogs/random-b.log"
            )
        ]

        let attachments = try FeedbackOutbox.makeZipAttachments(
            items: items,
            preparedDir: preparedDir,
            singleFilename: "logs.zip",
            numberedPrefix: "logs",
            attachmentType: .log,
            required: true,
            preferSingleArchiveWhenPossible: true
        )

        XCTAssertEqual(attachments.map(\.filename), ["logs-1.zip", "logs-2.zip"])
        XCTAssertTrue(attachments.allSatisfy { $0.attachmentType == .log })
        XCTAssertTrue(attachments.allSatisfy { $0.size <= FeedbackOutbox.maxAttachmentBytes })
        XCTAssertFalse(FileManager.default.fileExists(atPath: preparedDir.appendingPathComponent("logs.zip").path))
    }

    func testMakeZipAttachmentsNumbersFeedbackFilesAcrossBuckets() throws {
        let preparedDir = try makePreparedDirectory()
        let items = [
            archiveItem(path: "first.bin", plannedBytes: UInt64(FeedbackOutbox.zipPlanningBytes)),
            archiveItem(path: "second.bin", plannedBytes: 1)
        ]

        let attachments = try FeedbackOutbox.makeZipAttachments(
            items: items,
            preparedDir: preparedDir,
            singleFilename: nil,
            numberedPrefix: "feedback-files",
            attachmentType: .other,
            required: false
        )

        XCTAssertEqual(attachments.map(\.filename), ["feedback-files-1.zip", "feedback-files-2.zip"])
        XCTAssertEqual(attachments.map { $0.attachmentType.rawValue }, ["other", "other"])
        XCTAssertEqual(attachments.map(\.required), [false, false])
        XCTAssertTrue(attachments.allSatisfy { FileManager.default.fileExists(atPath: root.appendingPathComponent($0.relativePath).path) })
    }

    func testPrepareImageAttachmentsKeepsPreviewImagesBeforeImagesZip() throws {
        let jobRoot = try makeJobDirectory()
        let preparedDir = try makePreparedDirectory(in: jobRoot)
        let imagesDir = jobRoot.appendingPathComponent("images", isDirectory: true)
        try FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)

        let sources = try (1...5).map { index in
            let filename = "image-\(index).png"
            let fileURL = imagesDir.appendingPathComponent(filename)
            let data = Data(filename.utf8)
            try data.write(to: fileURL)
            return FeedbackOutboxSourceAttachment(
                relativePath: "images/\(filename)",
                filename: filename,
                mimeType: "image/png",
                size: Int64(data.count)
            )
        }

        let attachments = try FeedbackOutbox.prepareImageAttachments(
            jobRoot: jobRoot,
            preparedDir: preparedDir,
            sources: sources,
            preferredSlots: 3,
            maxSlots: 4
        )

        XCTAssertEqual(attachments.map(\.filename), ["image-1.png", "image-2.png", "images.zip"])
        XCTAssertEqual(attachments.map(\.mimeType), ["image/png", "image/png", "application/zip"])
        XCTAssertTrue(attachments.allSatisfy { $0.attachmentType == .screenshot })
        XCTAssertTrue(attachments.allSatisfy(\.required))
        XCTAssertTrue(attachments.allSatisfy { FileManager.default.fileExists(atPath: jobRoot.appendingPathComponent($0.relativePath).path) })
    }

    func testPrepareImageAttachmentsLetsSplitZipUseReservedSlot() throws {
        let jobRoot = try makeJobDirectory()
        let preparedDir = try makePreparedDirectory(in: jobRoot)
        let imagesDir = jobRoot.appendingPathComponent("images", isDirectory: true)
        try FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)

        let sources = try (1...5).map { index in
            let filename = "image-\(index).png"
            let fileURL = imagesDir.appendingPathComponent(filename)
            let data: Data
            if index <= 2 {
                data = Data(filename.utf8)
            } else {
                data = try randomData(byteCount: 8 * 1024 * 1024)
            }
            try data.write(to: fileURL)
            return FeedbackOutboxSourceAttachment(
                relativePath: "images/\(filename)",
                filename: filename,
                mimeType: "image/png",
                size: Int64(data.count)
            )
        }

        let attachments = try FeedbackOutbox.prepareImageAttachments(
            jobRoot: jobRoot,
            preparedDir: preparedDir,
            sources: sources,
            preferredSlots: 3,
            maxSlots: 4
        )

        XCTAssertEqual(attachments.map(\.filename), ["image-1.png", "image-2.png", "images-1.zip", "images-2.zip"])
        XCTAssertTrue(attachments.allSatisfy { $0.attachmentType == .screenshot })
        XCTAssertTrue(attachments.allSatisfy(\.required))
        XCTAssertTrue(attachments.allSatisfy { $0.size <= FeedbackOutbox.maxAttachmentBytes })
        XCTAssertFalse(FileManager.default.fileExists(atPath: preparedDir.appendingPathComponent("images.zip").path))
    }

    func testPrepareUserFileAttachmentsUsesOthersZip() throws {
        let jobRoot = try makeJobDirectory()
        let preparedDir = try makePreparedDirectory(in: jobRoot)
        let filesDir = jobRoot.appendingPathComponent("files", isDirectory: true)
        try FileManager.default.createDirectory(at: filesDir, withIntermediateDirectories: true)

        let firstURL = filesDir.appendingPathComponent("first.bin")
        FileManager.default.createFile(atPath: firstURL.path, contents: nil)
        let firstHandle = try FileHandle(forWritingTo: firstURL)
        try firstHandle.truncate(atOffset: UInt64(FeedbackOutbox.zipPlanningBytes))
        try firstHandle.close()

        let secondURL = filesDir.appendingPathComponent("second.bin")
        try Data("x".utf8).write(to: secondURL)

        let sources = [
            FeedbackOutboxSourceAttachment(
                relativePath: "files/first.bin",
                filename: "first.bin",
                mimeType: "application/octet-stream",
                size: FeedbackOutbox.zipPlanningBytes
            ),
            FeedbackOutboxSourceAttachment(
                relativePath: "files/second.bin",
                filename: "second.bin",
                mimeType: "application/octet-stream",
                size: 1
            )
        ]

        let attachments = try FeedbackOutbox.prepareUserFileAttachments(
            jobRoot: jobRoot,
            preparedDir: preparedDir,
            sources: sources,
            availableSlots: 1
        )

        XCTAssertEqual(attachments.map(\.filename), ["others.zip"])
        XCTAssertEqual(attachments[0].attachmentType, .other)
        XCTAssertTrue(attachments[0].required)
        XCTAssertFalse(FileManager.default.fileExists(atPath: preparedDir.appendingPathComponent("feedback-files-1.zip").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: preparedDir.appendingPathComponent("feedback-files-2.zip").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: jobRoot.appendingPathComponent(attachments[0].relativePath).path))
    }

    func testAttachmentsWithinSubmitLimitKeepsTenAndDropsOverflow() throws {
        let attachments = (0..<10).map { uploadAttachment(filename: "file-\($0).zip", required: true) }
        XCTAssertEqual(try FeedbackOutbox.attachmentsWithinSubmitLimit(required: attachments, optional: []).count, 10)
        let kept = try FeedbackOutbox.attachmentsWithinSubmitLimit(
            required: attachments, optional: [uploadAttachment(filename: "extra.zip", required: false)]
        )
        XCTAssertEqual(kept.map(\.filename), attachments.map(\.filename))
        XCTAssertEqual(try FeedbackOutbox.attachmentsWithinSubmitLimit(
            required: attachments + [uploadAttachment(filename: "extra-required.zip", required: true)], optional: []
        ).count, 10)
    }

    func testOptionalZipOverLimitIsSkippedAfterActualZipSizeCheck() throws {
        let preparedDir = try makePreparedDirectory()
        let data = try randomData(byteCount: Int(FeedbackOutbox.maxAttachmentBytes + 1024 * 1024))
        let item = ArchiveItem(
            sourceURL: nil,
            inlineData: data,
            offset: 0,
            length: UInt64(data.count),
            archivePath: "large-random.bin"
        )

        let attachments = try FeedbackOutbox.makeZipAttachments(
            items: [item],
            preparedDir: preparedDir,
            singleFilename: nil,
            numberedPrefix: "feedback-files",
            attachmentType: .other,
            required: false
        )

        XCTAssertTrue(attachments.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: preparedDir.appendingPathComponent("feedback-files-1.zip").path))
    }

    func testRequiredZipOverLimitIsSkippedAfterActualSizeCheck() throws {
        let preparedDir = try makePreparedDirectory()
        let data = try randomData(byteCount: Int(FeedbackOutbox.maxAttachmentBytes + 1024 * 1024))
        let item = ArchiveItem(
            sourceURL: nil,
            inlineData: data,
            offset: 0,
            length: UInt64(data.count),
            archivePath: "large-random.bin"
        )

        let attachments = try FeedbackOutbox.makeZipAttachments(
            items: [item],
            preparedDir: preparedDir,
            singleFilename: nil,
            numberedPrefix: "required-files",
            attachmentType: .screenshot,
            required: true
        )
        XCTAssertTrue(attachments.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: preparedDir.appendingPathComponent("required-files-1.zip").path))
    }

    func testSentinelCollectorUsesServiceFoldersAndOnlyCurrentStreams() throws {
        let main = root.appendingPathComponent("main")
        let services = root.appendingPathComponent("account/state/logs")
        try writeFixture("boot", at: main.appendingPathComponent("boot.log"))
        try writeFixture("do not collect", at: main.appendingPathComponent("boot.log.1"))
        try writeFixture("process", at: main.appendingPathComponent("ai-gateway-process.log"))
        for component in ["custom.component", "system.service-broker", "system.ai-gateway", "privacy-guard"] {
            try writeFixture("out-\(component)", at: services.appendingPathComponent("\(component)/stdout.log"))
            try writeFixture("err-\(component)", at: services.appendingPathComponent("\(component)/stderr.log"))
            try writeFixture("old", at: services.appendingPathComponent("\(component)/stderr.log.1"))
        }
        try writeFixture("audit", at: services.appendingPathComponent("runner/ipc-audit.log"))
        try writeFixture("model", at: services.appendingPathComponent("llm/model-id.log"))
        try writeFixture("old model", at: services.appendingPathComponent("llm/model-id.log.1"))
        try writeFixture("secret", at: services.appendingPathComponent("custom.component/config.json"))
        let job = try makeJobDirectory()
        let files = try FeedbackSentinelLogCollector.collect(mainLogsURL: main, serviceLogsURL: services, jobRoot: job)
        for component in ["custom.component", "system.service-broker", "system.ai-gateway", "privacy-guard"] {
            XCTAssertEqual(try snapshotText("services/\(component)/stdout.log", files: files, job: job), "out-\(component)")
            XCTAssertEqual(try snapshotText("services/\(component)/stderr.log", files: files, job: job), "err-\(component)")
        }
        XCTAssertEqual(try snapshotText("main/boot.log", files: files, job: job), "boot")
        XCTAssertEqual(try snapshotText("main/ai-gateway-process.log", files: files, job: job), "process")
        XCTAssertEqual(try snapshotText("audit/runner/ipc-audit.log", files: files, job: job), "audit")
        XCTAssertEqual(try snapshotText("services/llm/model-id.log", files: files, job: job), "model")
        XCTAssertFalse(files.contains { $0.archivePath.hasSuffix(".1") || $0.archivePath.hasSuffix(".json") })
        XCTAssertNil(files.first { $0.archivePath == "main/runner.log" }?.relativePath)
    }

    func testSentinelMissingCurrentFileNeverFallsBackToRotation() throws {
        let main = root.appendingPathComponent("main")
        try writeFixture("old runner", at: main.appendingPathComponent("runner.log.1"))
        let files = try FeedbackSentinelLogCollector.collect(mainLogsURL: main, serviceLogsURL: nil, jobRoot: makeJobDirectory())
        let runner = try XCTUnwrap(files.first { $0.archivePath == "main/runner.log" })
        XCTAssertNil(runner.relativePath)
        XCTAssertTrue(runner.status.hasPrefix("unavailable"))
    }

    func testSentinelCollectorRejectsSymlinkFilesAndDirectories() throws {
        let main = root.appendingPathComponent("main")
        let services = root.appendingPathComponent("services")
        let outside = root.appendingPathComponent("outside")
        try writeFixture("must stay private", at: outside.appendingPathComponent("stdout.log"))
        try FileManager.default.createDirectory(at: main, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: services, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: main.appendingPathComponent("boot.log"), withDestinationURL: outside.appendingPathComponent("stdout.log"))
        try FileManager.default.createSymbolicLink(at: services.appendingPathComponent("linked-service"), withDestinationURL: outside)
        let files = try FeedbackSentinelLogCollector.collect(mainLogsURL: main, serviceLogsURL: services, jobRoot: makeJobDirectory())
        XCTAssertFalse(files.contains { $0.relativePath != nil })
        XCTAssertFalse(files.contains { $0.archivePath.contains("linked-service") })
        // Also reject a symlink in the root's parent hierarchy.
        let linkedRoot = root.appendingPathComponent("linked-root")
        try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: root)
        let linkedFiles = try FeedbackSentinelLogCollector.collect(
            mainLogsURL: linkedRoot.appendingPathComponent("main"), serviceLogsURL: nil, jobRoot: makeJobDirectory()
        )
        XCTAssertFalse(linkedFiles.contains { $0.relativePath != nil })
    }

    func testSentinelCollectorBoundsHugeUnrotatedLogToFiveMiBTail() throws {
        let services = root.appendingPathComponent("services")
        let log = services.appendingPathComponent("llm/large-model.log")
        try writeFixture("old", at: log)
        let handle = try FileHandle(forWritingTo: log)
        let hugeSize: UInt64 = 8 * 1024 * 1024 * 1024
        try handle.truncate(atOffset: hugeSize)
        let expected = Data(repeating: 0x78, count: Int(FeedbackSentinelLogCollector.perStreamBytes))
        try handle.seek(toOffset: hugeSize - UInt64(expected.count))
        try handle.write(contentsOf: expected)
        try handle.close()
        let job = try makeJobDirectory()
        let files = try FeedbackSentinelLogCollector.collect(
            mainLogsURL: root.appendingPathComponent("missing"), serviceLogsURL: services, jobRoot: job
        )
        let record = try XCTUnwrap(files.first { $0.archivePath == "services/llm/large-model.log" })
        XCTAssertEqual(record.originalBytes, Int64(hugeSize))
        XCTAssertEqual(record.collectedBytes, 5 * 1024 * 1024)
        XCTAssertEqual(record.offset, Int64(hugeSize) - record.collectedBytes)
        XCTAssertTrue(record.truncated)
        XCTAssertEqual(try Data(contentsOf: job.appendingPathComponent(XCTUnwrap(record.relativePath))), expected)
    }

    func testSentinelTailAlignsToNewlineWithoutReadingHistory() throws {
        let main = root.appendingPathComponent("main")
        try writeFixture("discarded\nkeep\n", at: main.appendingPathComponent("boot.log"))
        let job = try makeJobDirectory()
        let files = try FeedbackSentinelLogCollector.collect(
            mainLogsURL: main, serviceLogsURL: nil, jobRoot: job, perStreamLimit: 8, totalLimit: 8
        )
        XCTAssertEqual(try snapshotText("main/boot.log", files: files, job: job), "keep\n")
        let boot = try XCTUnwrap(files.first { $0.archivePath == "main/boot.log" })
        XCTAssertEqual(boot.offset, 10)
        XCTAssertTrue(boot.truncated)
    }

    func testFairBudgetRedistributesShortStreamsAndDoesNotStarveLaterServices() {
        XCTAssertEqual(FeedbackSentinelLogCollector.fairBudgets(sizes: [0, 1, 8, 8], total: 10), [0, 1, 4, 5])
        XCTAssertEqual(FeedbackSentinelLogCollector.fairBudgets(sizes: [8, 1, 0, 8], total: 10), [4, 1, 0, 5])
        XCTAssertEqual(FeedbackSentinelLogCollector.fairBudgets(sizes: [2, 3], total: 10), [2, 3])
        XCTAssertEqual(FeedbackSentinelLogCollector.fairBudgets(sizes: [2, 3], total: 0), [0, 0])
        XCTAssertEqual(FeedbackSentinelLogCollector.fairBudgets(sizes: [], total: 10), [])
    }

    func testIncompressibleLogsReserveFiveUserSlotsAndDropExcessFiles() throws {
        let services = root.appendingPathComponent("services")
        let random = try randomData(byteCount: 5 * 1024 * 1024)
        for index in 0..<7 {
            for stream in ["stdout.log", "stderr.log"] {
                let url = services.appendingPathComponent("component-\(index)/\(stream)")
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try random.write(to: url)
            }
        }
        let job = try makeJobDirectory()
        let snapshot = try FeedbackOutbox.captureLogSnapshot(
            jobRoot: job, chromiumSystemLogs: nil,
            phiLogsURL: root.appendingPathComponent("missing-phi"),
            sentinelLogsURL: root.appendingPathComponent("missing-main"), sentinelServiceLogsURL: services
        )
        let streams = snapshot.sentinel.filter { $0.relativePath != nil }
        XCTAssertEqual(streams.count, 14)
        let total = streams.reduce(Int64(0)) { $0 + $1.collectedBytes }
        XCTAssertLessThanOrEqual(total, 64 * 1024 * 1024)
        XCTAssertGreaterThan(total, 63 * 1024 * 1024)
        XCTAssertTrue(streams.allSatisfy { $0.collectedBytes > 4 * 1024 * 1024 && $0.truncated })
        var manifest = testManifest(snapshot: snapshot)
        manifest.sourceImages = try (0..<5).map { index in
            try writeFixture("image-\(index)", at: job.appendingPathComponent("images/\(index).png"))
            return .init(relativePath: "images/\(index).png", filename: "\(index).png", mimeType: "image/png", size: 7)
        }
        let attachments = try FeedbackOutbox.prepareAttachments(jobRoot: job, manifest: manifest)
        XCTAssertEqual(attachments.count, 10)
        XCTAssertEqual(attachments.filter { $0.attachmentType == .log }.count, 5)
        XCTAssertEqual(attachments.filter { $0.attachmentType == .screenshot }.count, 5)
        XCTAssertTrue(attachments.allSatisfy { $0.size <= 20 * 1024 * 1024 && $0.required })
        let sentinelZIPs = attachments.filter { $0.filename.hasPrefix("sentinel-") }
        var archivedPaths = Set<String>()
        for attachment in sentinelZIPs {
            let zip = job.appendingPathComponent(attachment.relativePath)
            archivedPaths.formUnion(try zipEntries(in: zip))
            let report = try zipEntryText("collection-manifest.json", in: zip)
            XCTAssertFalse(report.contains(services.path))
            XCTAssertTrue(report.contains("truncated"))
        }
        for record in streams { XCTAssertTrue(archivedPaths.contains(record.archivePath)) }
        // Keep the file archives that fit the five remaining slots, dropping
        // excess archives without rejecting the feedback.
        let source = try XCTUnwrap(streams.first)
        manifest.sourceImages = []
        manifest.sourceFiles = (0..<21).map { index in
            .init(relativePath: source.relativePath!, filename: "selected-\(index).bin", mimeType: "application/octet-stream", size: source.collectedBytes)
        }
        let trimmed = try FeedbackOutbox.prepareAttachments(jobRoot: job, manifest: manifest)
        XCTAssertEqual(trimmed.count, 10)
        XCTAssertEqual(trimmed.filter { $0.attachmentType == .log }.count, 5)
        XCTAssertEqual(trimmed.filter { $0.attachmentType == .other }.count, 5)
        XCTAssertTrue(trimmed.allSatisfy { $0.size <= FeedbackOutbox.maxAttachmentBytes })
        XCTAssertFalse(FileManager.default.fileExists(atPath: job.appendingPathComponent("prepared/others-6.zip").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: job.appendingPathComponent(source.relativePath!).path))
    }

    func testPreparedSnapshotSurvivesRotationDeletionAndManifestRoundTrip() throws {
        let main = root.appendingPathComponent("main")
        let services = root.appendingPathComponent("services")
        try writeFixture("submission boot", at: main.appendingPathComponent("boot.log"))
        try writeFixture("submission error", at: services.appendingPathComponent("component/stderr.log"))
        let job = try makeJobDirectory()
        let snapshot = try FeedbackOutbox.captureLogSnapshot(
            jobRoot: job, chromiumSystemLogs: nil, phiLogsURL: root.appendingPathComponent("missing"),
            sentinelLogsURL: main, sentinelServiceLogsURL: services
        )
        try FileManager.default.removeItem(at: services)
        try FileManager.default.moveItem(at: main.appendingPathComponent("boot.log"), to: main.appendingPathComponent("boot.log.1"))
        try writeFixture("later session", at: main.appendingPathComponent("boot.log"))
        let manifest = try JSONDecoder().decode(FeedbackOutboxManifest.self, from: JSONEncoder().encode(testManifest(snapshot: snapshot)))
        for _ in 0..<2 {
            let attachments = try FeedbackOutbox.prepareAttachments(jobRoot: job, manifest: manifest)
            let sentinel = try XCTUnwrap(attachments.first { $0.filename == "sentinel-logs.zip" })
            let zip = job.appendingPathComponent(sentinel.relativePath)
            XCTAssertEqual(try zipEntryText("main/boot.log", in: zip), "submission boot")
            XCTAssertEqual(try zipEntryText("services/component/stderr.log", in: zip), "submission error")
            try FileManager.default.removeItem(at: job.appendingPathComponent("prepared"))
        }
        let saved = try XCTUnwrap(snapshot.sentinel.first { $0.archivePath == "main/boot.log" }?.relativePath)
        try FileManager.default.removeItem(at: job.appendingPathComponent(saved))
        XCTAssertThrowsError(try FeedbackOutbox.prepareAttachments(jobRoot: job, manifest: manifest))
    }

    func testUnusedLogSlotsReturnToUsersAndOrdinaryFilesAreRequired() throws {
        let job = try makeJobDirectory()
        let snapshot = try FeedbackOutbox.captureLogSnapshot(
            jobRoot: job, chromiumSystemLogs: nil, phiLogsURL: root.appendingPathComponent("missing"),
            sentinelLogsURL: root.appendingPathComponent("missing"), sentinelServiceLogsURL: nil
        )
        var manifest = testManifest(snapshot: snapshot)
        manifest.sourceImages = try (0..<7).map { index in
            try writeFixture("image", at: job.appendingPathComponent("images/\(index).png"))
            return .init(relativePath: "images/\(index).png", filename: "\(index).png", mimeType: "image/png", size: 5)
        }
        try writeFixture("file", at: job.appendingPathComponent("files/selected.txt"))
        manifest.sourceFiles = [.init(relativePath: "files/selected.txt", filename: "selected.txt", mimeType: "text/plain", size: 4)]
        let attachments = try FeedbackOutbox.prepareAttachments(jobRoot: job, manifest: manifest)
        XCTAssertEqual(attachments.count, 10)
        XCTAssertEqual(attachments.filter { $0.attachmentType == .screenshot }.count, 7)
        XCTAssertTrue(attachments.allSatisfy(\.required))
        let files = try XCTUnwrap(attachments.first { $0.filename == "others.zip" })
        XCTAssertEqual(try zipEntryText("selected.txt", in: job.appendingPathComponent(files.relativePath)), "file")
    }

    func testLegacyManifestDoesNotCollectLiveLogsWhenReprepared() throws {
        let job = try makeJobDirectory()
        let original = testManifest(snapshot: nil)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        object.removeValue(forKey: "logSnapshot")
        let manifest = try JSONDecoder().decode(FeedbackOutboxManifest.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(manifest.logSnapshot)
        XCTAssertTrue(try FeedbackOutbox.prepareAttachments(jobRoot: job, manifest: manifest).isEmpty)
    }

    func testPrepareJobValidatesBeforePublishingAndCleansUpRejectedJob() throws {
        let attachment = root.appendingPathComponent("too-large.bin")
        FileManager.default.createFile(atPath: attachment.path, contents: nil)
        let handle = try FileHandle(forWritingTo: attachment)
        try handle.truncate(atOffset: UInt64(FeedbackOutbox.maxSelectedAttachmentBytes + 1))
        try handle.close()
        let draft = FeedbackDraft(
            description: "Keep this draft", pageURL: "", pageTitle: nil, contactEmail: nil, components: [],
            chromiumSystemLogsText: nil,
            attachments: [.init(filename: "too-large.bin", size: FeedbackOutbox.maxSelectedAttachmentBytes + 1, kind: .file, source: .file(attachment))]
        )
        let job = root.appendingPathComponent("rejected-job")
        XCTAssertThrowsError(try FeedbackOutbox.prepareJob(
            draft, jobRoot: job, metadata: testManifest(snapshot: nil).metadata,
            phiLogsURL: root.appendingPathComponent("missing"), sentinelLogsURL: root.appendingPathComponent("missing"), sentinelServiceLogsURL: nil
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: job.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: attachment.path))
        XCTAssertEqual(draft.description, "Keep this draft")
    }

    func testSentinelServiceLogPathSeparatesChannelsAndSanitizesAccount() throws {
        for (browser, sentinel) in [
            ("com.phibrowser.Mac", "com.phibrowser.Sentinel"),
            ("com.phibrowser.canary.Mac", "com.phibrowser.canary.Sentinel"),
            ("com.phibrowser.dev.Mac", "com.phibrowser.dev.Sentinel")
        ] {
            let url = try XCTUnwrap(SentinelHelper.sentinelServiceLogsDirectoryURL(
                auth0Subject: "auth0|abc", browserBundleIdentifier: browser, applicationSupportURL: root
            ))
            XCTAssertEqual(url.path, root.appendingPathComponent("\(sentinel)/auth0_abc/state/logs").path)
        }
        XCTAssertNil(SentinelHelper.sentinelServiceLogsDirectoryURL(auth0Subject: ""))
        XCTAssertTrue(try XCTUnwrap(SentinelHelper.sentinelServiceLogsDirectoryURL(auth0Subject: "..")).path.hasSuffix("/_/state/logs"))
    }

    @MainActor
    func testSubmittingDraftRejectsLateAttachmentEvents() throws {
        let file = root.appendingPathComponent("selected.txt")
        try writeFixture("selected", at: file)
        let model = FeedbackViewModel()
        model.addFileURLs([file])
        let id = try XCTUnwrap(model.attachments.first?.id)
        let image = NSImage(size: NSSize(width: 2, height: 2))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 2, height: 2).fill()
        image.unlockFocus()
        model.isSubmitting = true
        model.addFileURLs([file])
        model.addPastedImage(image)
        model.removeAttachment(id: id)
        XCTAssertEqual(model.attachments.count, 1)
        XCTAssertEqual(model.attachments.first?.id, id)
        model.isSubmitting = false
        model.addPastedImage(image)
        XCTAssertEqual(model.attachments.count, 2)
    }

    func testPreparedJobContainsValidatedArchivesButIsNotPublishedEarly() throws {
        let main = root.appendingPathComponent("main")
        let services = root.appendingPathComponent("services")
        try writeFixture("out", at: services.appendingPathComponent("component/stdout.log"))
        try writeFixture("", at: services.appendingPathComponent("component/stderr.log"))
        let selected = root.appendingPathComponent("selected.txt")
        try writeFixture("user file", at: selected)
        let draft = FeedbackDraft(
            description: "Report", pageURL: "", pageTitle: nil, contactEmail: nil, components: [],
            chromiumSystemLogsText: "system logs", attachments: [
                .init(filename: "selected.txt", size: 9, kind: .file, source: .file(selected))
            ]
        )
        let job = root.appendingPathComponent("prepared-job")
        let manifest = try FeedbackOutbox.prepareJob(
            draft, jobRoot: job, metadata: testManifest(snapshot: nil).metadata,
            phiLogsURL: root.appendingPathComponent("missing"), sentinelLogsURL: main, sentinelServiceLogsURL: services
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: job.appendingPathComponent("manifest.json").path))
        XCTAssertEqual(manifest.preparedAttachments.count, 3)
        XCTAssertTrue(manifest.preparedAttachments.allSatisfy { $0.required && $0.size <= FeedbackOutbox.maxAttachmentBytes })
        let empty = try XCTUnwrap(manifest.logSnapshot?.sentinel.first { $0.archivePath == "services/component/stderr.log" })
        XCTAssertEqual(empty.status, "empty")
        XCTAssertEqual(empty.collectedBytes, 0)
        let sentinel = try XCTUnwrap(manifest.preparedAttachments.first { $0.filename == "sentinel-logs.zip" })
        XCTAssertTrue(try zipEntries(in: job.appendingPathComponent(sentinel.relativePath)).contains("services/component/stderr.log"))
        let user = try XCTUnwrap(manifest.preparedAttachments.first { $0.filename == "others.zip" })
        XCTAssertEqual(try zipEntryText("selected.txt", in: job.appendingPathComponent(user.relativePath)), "user file")
    }

    func testNoRemainingSlotsSkipsImagesAndFilesWithoutReadingSources() throws {
        let job = try makeJobDirectory()
        let prepared = try makePreparedDirectory(in: job)
        let missing = FeedbackOutboxSourceAttachment(
            relativePath: "missing", filename: "missing", mimeType: "application/octet-stream", size: 1
        )
        XCTAssertTrue(try FeedbackOutbox.prepareImageAttachments(
            jobRoot: job, preparedDir: prepared, sources: [missing], preferredSlots: 0, maxSlots: 0
        ).isEmpty)
        XCTAssertTrue(try FeedbackOutbox.prepareUserFileAttachments(
            jobRoot: job, preparedDir: prepared, sources: [missing], availableSlots: 0
        ).isEmpty)
    }

    func testImageOverflowKeepsFirstArchiveAndRemovesExcessArchive() throws {
        let job = try makeJobDirectory()
        let prepared = try makePreparedDirectory(in: job)
        let sources = try (1...2).map { index -> FeedbackOutboxSourceAttachment in
            let filename = "image-\(index).png"
            let data = try randomData(byteCount: 11 * 1024 * 1024)
            try data.write(to: job.appendingPathComponent(filename))
            return .init(relativePath: filename, filename: filename, mimeType: "image/png", size: Int64(data.count))
        }
        let attachments = try FeedbackOutbox.prepareImageAttachments(
            jobRoot: job, preparedDir: prepared, sources: sources, preferredSlots: 1, maxSlots: 1
        )
        XCTAssertEqual(attachments.map(\.filename), ["images-1.zip"])
        XCTAssertLessThanOrEqual(attachments[0].size, FeedbackOutbox.maxAttachmentBytes)
        let entries = try zipEntries(in: job.appendingPathComponent(attachments[0].relativePath))
        XCTAssertTrue(entries.contains("images/image-1.png"))
        XCTAssertFalse(entries.contains("images/image-2.png"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.appendingPathComponent("images-2.zip").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: job.appendingPathComponent("image-2.png").path))
    }

    func testOversizedFileSourceIsSkippedWhileOtherFilesAreKept() throws {
        let job = try makeJobDirectory()
        let prepared = try makePreparedDirectory(in: job)
        try writeFixture("keep", at: job.appendingPathComponent("small.txt"))
        let attachments = try FeedbackOutbox.prepareUserFileAttachments(
            jobRoot: job, preparedDir: prepared, sources: [
                .init(relativePath: "oversized.bin", filename: "oversized.bin", mimeType: "application/octet-stream", size: FeedbackOutbox.maxAttachmentBytes + 1),
                .init(relativePath: "small.txt", filename: "small.txt", mimeType: "text/plain", size: 4)
            ], availableSlots: 1
        )
        XCTAssertEqual(attachments.count, 1)
        let zip = job.appendingPathComponent(attachments[0].relativePath)
        XCTAssertEqual(try zipEntryText("small.txt", in: zip), "keep")
        XCTAssertFalse(try zipEntries(in: zip).contains("oversized.bin"))
    }

    private func writeFixture(_ text: String, at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func snapshotText(_ path: String, files: [FeedbackLogSnapshot.File], job: URL) throws -> String {
        let file = try XCTUnwrap(files.first { $0.archivePath == path })
        return try String(contentsOf: job.appendingPathComponent(XCTUnwrap(file.relativePath)), encoding: .utf8)
    }

    private func testManifest(snapshot: FeedbackLogSnapshot?) -> FeedbackOutboxManifest {
        let metadata = FeedbackV2Metadata(
            browser: .init(name: "Phi", version: "test", channel: nil, revision: nil, aiEnabled: nil, useNTP: nil),
            page: nil, clientContext: .init(category: nil, userAgent: nil, locale: nil, traceID: nil), components: [], extra: [:]
        )
        return FeedbackOutboxManifest(
            id: "test", createdAt: Date(), description: "Test report", contactEmail: nil, metadata: metadata,
            sourceImages: [], sourceFiles: [], chromiumSystemLogs: nil, preparedAttachments: [],
            archiveStrategyVersion: FeedbackOutbox.archiveStrategyVersion, status: .queued, retryCount: 0,
            nextAttemptAt: nil, lastError: nil, logSnapshot: snapshot
        )
    }

    private func zipEntries(in zipURL: URL) throws -> [String] {
        let output = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-Z1", zipURL.path]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    private func makeJobDirectory() throws -> URL {
        let jobRoot = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: jobRoot, withIntermediateDirectories: true)
        return jobRoot
    }

    private func makePreparedDirectory(in parent: URL? = nil) throws -> URL {
        let preparedDir = (parent ?? root).appendingPathComponent("prepared", isDirectory: true)
        try FileManager.default.createDirectory(at: preparedDir, withIntermediateDirectories: true)
        return preparedDir
    }

    private func uploadAttachment(filename: String, required: Bool) -> FeedbackOutboxUploadAttachment {
        FeedbackOutboxUploadAttachment(
            id: UUID().uuidString,
            relativePath: "prepared/\(filename)",
            filename: filename,
            mimeType: "application/zip",
            size: 1,
            attachmentType: required ? .log : .other,
            required: required,
            status: .queued,
            retryCount: 0,
            objectKey: nil
        )
    }

    private func archiveItem(path: String, plannedBytes: UInt64) -> ArchiveItem {
        ArchiveItem(
            sourceURL: nil,
            inlineData: Data("x".utf8),
            offset: 0,
            length: plannedBytes,
            archivePath: path
        )
    }

    private func archiveItem(path: String, inlineText: String) -> ArchiveItem {
        let data = Data(inlineText.utf8)
        return ArchiveItem(
            sourceURL: nil,
            inlineData: data,
            offset: 0,
            length: UInt64(data.count),
            archivePath: path
        )
    }

    private func zipEntryText(_ entry: String, in zipURL: URL) throws -> String {
        let output = Pipe()
        let errorOutput = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", zipURL.path, entry]
        process.standardOutput = output
        process.standardError = errorOutput
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let message = String(data: errorOutput.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw NSError(
                domain: "FeedbackOutboxArchiveTests",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }

        return String(data: data, encoding: .utf8) ?? ""
    }

    private func zipEntryExists(_ entry: String, in zipURL: URL) throws -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", zipURL.path, entry]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    @discardableResult
    private func writeLog(_ text: String, named filename: String, in directory: URL, modifiedAt: Date) throws -> URL {
        let url = directory.appendingPathComponent(filename)
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: url.path)
        return url
    }

    private func randomData(byteCount: Int) throws -> Data {
        var data = Data(count: byteCount)
        let status = data.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, byteCount, bytes.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw NSError(domain: "FeedbackOutboxArchiveTests", code: Int(status))
        }
        return data
    }
}

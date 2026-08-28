// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

enum TimeMachineSnapshotError: Error, LocalizedError {
    case missingApplicationSupport(URL)
    case missingPhiData(URL)
    case snapshotAlreadyExists(URL)

    var errorDescription: String? {
        switch self {
        case .missingApplicationSupport(let url):
            return "Missing application support directory at \(url.path)"
        case .missingPhiData(let url):
            return "Missing Phi data directory at \(url.path)"
        case .snapshotAlreadyExists(let url):
            return "Time Machine snapshot already exists at \(url.path)"
        }
    }
}

struct TimeMachineSnapshotManager {
    typealias BackupTraceReporter = (TimeMachineBackupTrace) -> Void

    private let paths: TimeMachinePaths
    private let policyLoader: TimeMachineRollbackPolicyLoader
    private let backupTriggerMode: TimeMachineBackupTriggerMode
    private let catalogStore: TimeMachineCatalogStore
    private let applicationSupportURLProvider: () -> URL
    private let phiDataURLProvider: () -> URL
    private let preferencesURLProvider: () -> URL
    private let dateProvider: () -> Date
    private let uptimeProvider: () -> TimeInterval
    private let idProvider: () -> UUID
    private let fileCloner: TimeMachineFileCloner
    private let backupTraceReporter: BackupTraceReporter
    private let fileManager: FileManager

    init(
        paths: TimeMachinePaths = TimeMachinePaths(),
        policyLoader: TimeMachineRollbackPolicyLoader = TimeMachineRollbackPolicyLoader(),
        backupTriggerMode: TimeMachineBackupTriggerMode = .current,
        catalogStore: TimeMachineCatalogStore? = nil,
        applicationSupportURLProvider: @escaping () -> URL = {
            URL(fileURLWithPath: FileSystemUtils.applicationSupportDirctory(), isDirectory: true)
        },
        phiDataURLProvider: @escaping () -> URL = {
            URL(fileURLWithPath: FileSystemUtils.phiBrowserDataDirectory(), isDirectory: true)
        },
        preferencesURLProvider: @escaping () -> URL = {
            URL(fileURLWithPath: FileSystemUtils.plistPath(), isDirectory: false)
        },
        dateProvider: @escaping () -> Date = Date.init,
        uptimeProvider: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        idProvider: @escaping () -> UUID = UUID.init,
        fileCloner: TimeMachineFileCloner = TimeMachineFileCloner(),
        backupTraceReporter: @escaping BackupTraceReporter = SentryService.captureTimeMachineBackupTrace,
        fileManager: FileManager = .default
    ) {
        self.paths = paths
        self.policyLoader = policyLoader
        self.backupTriggerMode = backupTriggerMode
        self.catalogStore = catalogStore ?? TimeMachineCatalogStore(paths: paths)
        self.applicationSupportURLProvider = applicationSupportURLProvider
        self.phiDataURLProvider = phiDataURLProvider
        self.preferencesURLProvider = preferencesURLProvider
        self.dateProvider = dateProvider
        self.uptimeProvider = uptimeProvider
        self.idProvider = idProvider
        self.fileCloner = fileCloner
        self.backupTraceReporter = backupTraceReporter
        self.fileManager = fileManager
    }

    func prepareBackupIfNeeded(currentVersion: String, currentBuild: Int) throws -> TimeMachineBackupRecord? {
        guard let policy = try policyLoader.loadPolicy() else {
            AppLogDebug("[TimeMachine] No rollback policy found; skipping backup.")
            return nil
        }

        guard policy.shouldCreateBackup(
            currentVersion: currentVersion,
            currentBuild: currentBuild,
            triggerMode: backupTriggerMode
        ) else {
            AppLogDebug(
                "[TimeMachine] Backup policy skipped version \(currentVersion) build \(currentBuild); " +
                "trigger \(backupTriggerDescription(for: policy))."
            )
            return nil
        }

        let catalog = try catalogStore.load()
        guard !hasHandledBackup(in: catalog, for: policy) else {
            AppLogInfo(
                "[TimeMachine] Backup already exists for trigger \(backupTriggerDescription(for: policy)); " +
                "skipping duplicate snapshot."
            )
            return nil
        }

        let id = idProvider()
        let createdAt = dateProvider()
        let startedAt = uptimeProvider()
        let stagingURL = paths.snapshotStagingURL(id: id)
        let snapshotURL = paths.snapshotURL(id: id)

        guard !fileManager.fileExists(atPath: snapshotURL.path) else {
            AppLogError("[TimeMachine] Snapshot \(id.uuidString) already exists at \(snapshotURL.path).")
            throw TimeMachineSnapshotError.snapshotAlreadyExists(snapshotURL)
        }

        AppLogInfo(
            "[TimeMachine] Starting backup id=\(id.uuidString) current=\(currentVersion) build=\(currentBuild) " +
            "rollback=\(policy.rollbackVersion) build=\(policy.rollbackBuild) scope=\(scopeDescription(policy.includeChromiumData)) " +
            "bundle=\(paths.bundleIdentifier) root=\(paths.rootURL.path)"
        )
        do {
            if fileManager.fileExists(atPath: stagingURL.path) {
                AppLogInfo("[TimeMachine] Removing stale backup staging directory at \(stagingURL.path).")
                try fileManager.removeItem(at: stagingURL)
            }
            try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: true)
            AppLogInfo("[TimeMachine] Backup staging directory created at \(stagingURL.path).")

            let manifest = try createSnapshotContents(
                id: id,
                createdAt: createdAt,
                currentVersion: currentVersion,
                currentBuild: currentBuild,
                policy: policy,
                stagingURL: stagingURL,
                snapshotURL: snapshotURL
            )
            try writeManifest(manifest, to: stagingURL)
            AppLogInfo("[TimeMachine] Backup manifest written for snapshot \(id.uuidString).")
            try fileManager.moveItem(at: stagingURL, to: snapshotURL)
            AppLogInfo("[TimeMachine] Backup staging committed to \(snapshotURL.path).")

            let recordWithoutSize = TimeMachineBackupRecord(
                id: id,
                createdAt: createdAt,
                creatingVersion: currentVersion,
                creatingBuild: currentBuild,
                backupTriggerBuild: policy.backupTriggerBuild,
                rollbackVersion: policy.rollbackVersion,
                rollbackBuild: policy.rollbackBuild,
                rollbackPackageURL: policy.rollbackPackageURL,
                rollbackPackageSHA256: policy.rollbackPackageSHA256,
                includeChromiumData: policy.includeChromiumData,
                snapshotRelativePath: paths.relativePath(for: snapshotURL),
                status: .completed,
                rollbackAppBundleName: policy.rollbackAppBundleName
            )
            try catalogStore.appendCompletedBackup(recordWithoutSize)
            AppLogInfo("[TimeMachine] Backup catalog updated for snapshot \(id.uuidString).")
            let snapshotSizeBytes = TimeMachineFileMetrics.sizeBytes(at: snapshotURL, fileManager: fileManager)
            let record: TimeMachineBackupRecord
            if let snapshotSizeBytes {
                do {
                    record = try catalogStore.updateSnapshotSizeBytes(
                        id: id,
                        sizeBytes: snapshotSizeBytes
                    ) ?? recordWithoutSize
                } catch {
                    AppLogError(
                        "[TimeMachine] Backup \(id.uuidString) completed, but its data size could not be stored: "
                            + error.localizedDescription
                    )
                    record = recordWithoutSize
                }
            } else {
                record = recordWithoutSize
            }
            let duration = elapsedDuration(since: startedAt)
            backupTraceReporter(
                TimeMachineBackupTrace(
                    result: .succeeded,
                    backupID: id,
                    bundleIdentifier: paths.bundleIdentifier,
                    currentVersion: currentVersion,
                    currentBuild: currentBuild,
                    backupTriggerBuild: policy.backupTriggerBuild,
                    rollbackVersion: policy.rollbackVersion,
                    rollbackBuild: policy.rollbackBuild,
                    includeChromiumData: policy.includeChromiumData,
                    duration: duration,
                    snapshotSizeBytes: snapshotSizeBytes,
                    errorDescription: nil,
                    errorType: nil
                )
            )
            AppLogInfo(
                "[TimeMachine] Backup \(id.uuidString) completed in \(formatDuration(duration)); " +
                "size=\(snapshotSizeBytes.map(String.init) ?? "unknown") bytes."
            )
            return record
        } catch {
            let duration = elapsedDuration(since: startedAt)
            let snapshotSizeBytes = TimeMachineFileMetrics.sizeBytes(at: stagingURL, fileManager: fileManager)
                ?? TimeMachineFileMetrics.sizeBytes(at: snapshotURL, fileManager: fileManager)
            backupTraceReporter(
                TimeMachineBackupTrace(
                    result: .failed,
                    backupID: id,
                    bundleIdentifier: paths.bundleIdentifier,
                    currentVersion: currentVersion,
                    currentBuild: currentBuild,
                    backupTriggerBuild: policy.backupTriggerBuild,
                    rollbackVersion: policy.rollbackVersion,
                    rollbackBuild: policy.rollbackBuild,
                    includeChromiumData: policy.includeChromiumData,
                    duration: duration,
                    snapshotSizeBytes: snapshotSizeBytes,
                    errorDescription: error.localizedDescription,
                    errorType: String(describing: type(of: error))
                )
            )
            AppLogError("[TimeMachine] Backup \(id.uuidString) failed after \(formatDuration(duration)): \(error.localizedDescription)")
            try? fileManager.removeItem(at: stagingURL)
            try? fileManager.removeItem(at: snapshotURL)
            throw error
        }
    }

    private func createSnapshotContents(
        id: UUID,
        createdAt: Date,
        currentVersion: String,
        currentBuild: Int,
        policy: TimeMachineRollbackPolicy,
        stagingURL: URL,
        snapshotURL: URL
    ) throws -> TimeMachineSnapshotManifest {
        let appSupportSnapshotURL = stagingURL
            .appendingPathComponent("ApplicationSupport", isDirectory: true)
            .appendingPathComponent(paths.bundleIdentifier, isDirectory: true)
        let finalAppSupportSnapshotURL = snapshotURL
            .appendingPathComponent("ApplicationSupport", isDirectory: true)
            .appendingPathComponent(paths.bundleIdentifier, isDirectory: true)

        let copiedApplicationSupportPath: String?
        let copiedPhiDataPath: String?
        if policy.includeChromiumData {
            let sourceURL = applicationSupportURLProvider()
            guard fileManager.fileExists(atPath: sourceURL.path) else {
                AppLogError("[TimeMachine] Full backup source is missing at \(sourceURL.path).")
                throw TimeMachineSnapshotError.missingApplicationSupport(sourceURL)
            }
            AppLogInfo("[TimeMachine] Copying full application support data from \(sourceURL.path) to \(appSupportSnapshotURL.path).")
            try fileCloner.copyItem(at: sourceURL, to: appSupportSnapshotURL)
            AppLogInfo("[TimeMachine] Full application support data copied for snapshot \(id.uuidString).")
            copiedApplicationSupportPath = paths.relativePath(for: finalAppSupportSnapshotURL)
            let phiDataURL = appSupportSnapshotURL.appendingPathComponent("Phi", isDirectory: true)
            copiedPhiDataPath = fileManager.fileExists(atPath: phiDataURL.path)
                ? paths.relativePath(
                    for: finalAppSupportSnapshotURL.appendingPathComponent("Phi", isDirectory: true)
                )
                : nil
        } else {
            let sourceURL = phiDataURLProvider()
            guard fileManager.fileExists(atPath: sourceURL.path) else {
                AppLogError("[TimeMachine] Phi-only backup source is missing at \(sourceURL.path).")
                throw TimeMachineSnapshotError.missingPhiData(sourceURL)
            }
            let destinationURL = appSupportSnapshotURL.appendingPathComponent("Phi", isDirectory: true)
            let finalDestinationURL = finalAppSupportSnapshotURL.appendingPathComponent("Phi", isDirectory: true)
            AppLogInfo("[TimeMachine] Copying Phi data from \(sourceURL.path) to \(destinationURL.path).")
            try fileCloner.copyItem(at: sourceURL, to: destinationURL)
            AppLogInfo("[TimeMachine] Phi data copied for snapshot \(id.uuidString).")
            copiedApplicationSupportPath = nil
            copiedPhiDataPath = paths.relativePath(for: finalDestinationURL)
        }

        let copiedPreferencesPath = try copyPreferencesIfPresent(to: stagingURL, snapshotURL: snapshotURL)

        return TimeMachineSnapshotManifest(
            id: id,
            createdAt: createdAt,
            creatingVersion: currentVersion,
            creatingBuild: currentBuild,
            backupTriggerBuild: policy.backupTriggerBuild,
            rollbackVersion: policy.rollbackVersion,
            rollbackBuild: policy.rollbackBuild,
            rollbackPackageURL: policy.rollbackPackageURL,
            rollbackPackageSHA256: policy.rollbackPackageSHA256,
            includeChromiumData: policy.includeChromiumData,
            applicationSupportRelativePath: copiedApplicationSupportPath,
            phiDataRelativePath: copiedPhiDataPath,
            preferencesRelativePath: copiedPreferencesPath,
            rollbackAppBundleName: policy.rollbackAppBundleName
        )
    }

    private func copyPreferencesIfPresent(to stagingURL: URL, snapshotURL: URL) throws -> String? {
        let sourceURL = preferencesURLProvider()
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            AppLogInfo("[TimeMachine] Preferences file not found at \(sourceURL.path); backup will continue without preferences.")
            return nil
        }

        let destinationURL = stagingURL
            .appendingPathComponent("Preferences", isDirectory: true)
            .appendingPathComponent("\(paths.bundleIdentifier).plist", isDirectory: false)
        let finalDestinationURL = snapshotURL
            .appendingPathComponent("Preferences", isDirectory: true)
            .appendingPathComponent("\(paths.bundleIdentifier).plist", isDirectory: false)
        AppLogInfo("[TimeMachine] Copying preferences from \(sourceURL.path) to \(destinationURL.path).")
        try fileCloner.copyItem(at: sourceURL, to: destinationURL)
        AppLogInfo("[TimeMachine] Preferences copied for backup.")
        return paths.relativePath(for: finalDestinationURL)
    }

    private func writeManifest(_ manifest: TimeMachineSnapshotManifest, to snapshotURL: URL) throws {
        let data = try Self.encoder.encode(manifest)
        try data.write(
            to: snapshotURL.appendingPathComponent(TimeMachineSnapshotManifest.filename),
            options: .atomic
        )
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private func scopeDescription(_ includeChromiumData: Bool) -> String {
        includeChromiumData ? "full" : "phi-only"
    }

    private func hasHandledBackup(in catalog: TimeMachineCatalog, for policy: TimeMachineRollbackPolicy) -> Bool {
        switch backupTriggerMode {
        case .build:
            return catalog.hasHandledBackup(triggerBuild: policy.backupTriggerBuild)
        case .version:
            return catalog.hasHandledBackup(creatingVersion: policy.backupTriggerVersion)
        }
    }

    private func backupTriggerDescription(for policy: TimeMachineRollbackPolicy) -> String {
        switch backupTriggerMode {
        case .build:
            return "build \(policy.backupTriggerBuild)"
        case .version:
            return "version \(policy.backupTriggerVersion)"
        }
    }

    private func formatDuration(since startedAt: TimeInterval) -> String {
        formatDuration(elapsedDuration(since: startedAt))
    }

    private func elapsedDuration(since startedAt: TimeInterval) -> TimeInterval {
        max(0, uptimeProvider() - startedAt)
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        String(format: "%.3fs", max(0, duration))
    }
}

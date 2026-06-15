// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

struct LocalStoreOpenPlan {
    let activeStoreFormatVersion: Int
    let targetStoreFormatVersion: Int
    let manifestWasCreated: Bool
    let createdBackup: LocalStoreBackupRecord?
    let restoredBackup: LocalStoreBackupRecord?
}

struct LocalStoreRequiresNewerAppIssue: Equatable {
    let activeStoreFormatVersion: Int
    let currentStoreFormatVersion: Int
    let readableStoreFormatVersions: ClosedRange<Int>
}

enum LocalStoreCompatibilityResult {
    case ready(LocalStoreOpenPlan)
    case requiresNewerApp(LocalStoreRequiresNewerAppIssue)
}

enum LocalStoreCompatibilityStatus {
    case notChecked
    case ready(LocalStoreOpenPlan)
    case requiresNewerApp(LocalStoreRequiresNewerAppIssue)
    case failed(String)
}

enum LocalStoreCompatibilityError: Error, LocalizedError {
    case missingStoreFile(URL)
    case missingBackupStoreFile(URL)

    var errorDescription: String? {
        switch self {
        case .missingStoreFile(let url):
            "Missing local store file at \(url.path)"
        case .missingBackupStoreFile(let url):
            "Missing backup store file at \(url.path)"
        }
    }
}

final class LocalStoreCompatibilityController {
    private let configuration: LocalStoreCompatibilityConfiguration
    private let fileManager: FileManager

    init(configuration: LocalStoreCompatibilityConfiguration, fileManager: FileManager = .default) {
        self.configuration = configuration
        self.fileManager = fileManager
    }

    func prepareStore(at storeDirectory: URL) throws -> LocalStoreCompatibilityResult {
        try fileManager.createDirectory(at: storeDirectory, withIntermediateDirectories: true)

        var manifestState = try loadManifest(from: storeDirectory)
        if !configuration.canReadStoreFormatVersion(manifestState.manifest.activeStoreFormatVersion) {
            guard let backup = bestReadableBackup(in: manifestState.manifest, storeDirectory: storeDirectory) else {
                return .requiresNewerApp(
                    LocalStoreRequiresNewerAppIssue(
                        activeStoreFormatVersion: manifestState.manifest.activeStoreFormatVersion,
                        currentStoreFormatVersion: configuration.currentStoreFormatVersion,
                        readableStoreFormatVersions: configuration.readableStoreFormatVersions
                    )
                )
            }

            try restoreBackup(backup, in: storeDirectory)
            manifestState.manifest.activeStoreFormatVersion = backup.storeFormatVersion
            try saveManifest(manifestState.manifest, to: storeDirectory)
            return .ready(
                LocalStoreOpenPlan(
                    activeStoreFormatVersion: backup.storeFormatVersion,
                    targetStoreFormatVersion: configuration.currentStoreFormatVersion,
                    manifestWasCreated: manifestState.wasCreated,
                    createdBackup: nil,
                    restoredBackup: backup
                )
            )
        }

        var createdBackup: LocalStoreBackupRecord?
        let backupContext = LocalStoreBackupContext(
            activeStoreFormatVersion: manifestState.manifest.activeStoreFormatVersion,
            currentStoreFormatVersion: configuration.currentStoreFormatVersion,
            existingBackups: manifestState.manifest.backups
        )
        if configuration.backupPolicy.shouldBackupBeforeOpening(backupContext) {
            let backup = try createBackup(
                forStoreFormatVersion: manifestState.manifest.activeStoreFormatVersion,
                beforeUpgradingToStoreFormatVersion: configuration.currentStoreFormatVersion,
                in: storeDirectory
            )
            manifestState.manifest.backups.append(backup)
            createdBackup = backup
        }

        try saveManifest(manifestState.manifest, to: storeDirectory)
        return .ready(
            LocalStoreOpenPlan(
                activeStoreFormatVersion: manifestState.manifest.activeStoreFormatVersion,
                targetStoreFormatVersion: configuration.currentStoreFormatVersion,
                manifestWasCreated: manifestState.wasCreated,
                createdBackup: createdBackup,
                restoredBackup: nil
            )
        )
    }

    func markStoreOpenedSuccessfully(_ plan: LocalStoreOpenPlan, at storeDirectory: URL) throws {
        var manifestState = try loadManifest(from: storeDirectory)
        manifestState.manifest.activeStoreFormatVersion = plan.targetStoreFormatVersion
        if let restoredBackup = plan.restoredBackup {
            manifestState.manifest.backups.removeAll { $0.id == restoredBackup.id }
        }
        try saveManifest(manifestState.manifest, to: storeDirectory)
        if let restoredBackup = plan.restoredBackup {
            try deleteBackup(restoredBackup, in: storeDirectory)
        }
    }

    private func loadManifest(from storeDirectory: URL) throws -> (manifest: LocalStoreCompatibilityManifest, wasCreated: Bool) {
        let url = manifestURL(in: storeDirectory)
        guard fileManager.fileExists(atPath: url.path) else {
            return (
                LocalStoreCompatibilityManifest(
                    activeStoreFormatVersion: configuration.currentStoreFormatVersion,
                    backups: []
                ),
                true
            )
        }

        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try decoder.decode(LocalStoreCompatibilityManifest.self, from: data), false)
    }

    private func saveManifest(_ manifest: LocalStoreCompatibilityManifest, to storeDirectory: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        try data.write(to: manifestURL(in: storeDirectory), options: .atomic)
    }

    private func createBackup(
        forStoreFormatVersion storeFormatVersion: Int,
        beforeUpgradingToStoreFormatVersion targetStoreFormatVersion: Int,
        in storeDirectory: URL
    ) throws -> LocalStoreBackupRecord {
        let mainStoreURL = storeDirectory.appendingPathComponent(configuration.storeFilename)
        guard fileManager.fileExists(atPath: mainStoreURL.path) else {
            throw LocalStoreCompatibilityError.missingStoreFile(mainStoreURL)
        }

        let backupID = uniqueBackupID(in: storeDirectory)
        let directoryName = "\(configuration.backupsDirectoryName)/\(backupID)"
        let backupDirectory = storeDirectory.appendingPathComponent(directoryName, isDirectory: true)
        try fileManager.createDirectory(at: backupDirectory, withIntermediateDirectories: true)

        for fileName in storeFileNames {
            let sourceURL = storeDirectory.appendingPathComponent(fileName)
            guard fileManager.fileExists(atPath: sourceURL.path) else {
                continue
            }
            try fileManager.copyItem(at: sourceURL, to: backupDirectory.appendingPathComponent(fileName))
        }

        return LocalStoreBackupRecord(
            id: backupID,
            storeFormatVersion: storeFormatVersion,
            directoryName: directoryName,
            createdAt: configuration.dateProvider(),
            createdBeforeUpgradingToStoreFormatVersion: targetStoreFormatVersion
        )
    }

    private func restoreBackup(_ backup: LocalStoreBackupRecord, in storeDirectory: URL) throws {
        let backupDirectory = storeDirectory.appendingPathComponent(backup.directoryName, isDirectory: true)
        let backupStoreURL = backupDirectory.appendingPathComponent(configuration.storeFilename)
        guard fileManager.fileExists(atPath: backupStoreURL.path) else {
            throw LocalStoreCompatibilityError.missingBackupStoreFile(backupStoreURL)
        }

        for fileName in storeFileNames {
            let destinationURL = storeDirectory.appendingPathComponent(fileName)
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }

            let sourceURL = backupDirectory.appendingPathComponent(fileName)
            if fileManager.fileExists(atPath: sourceURL.path) {
                try fileManager.copyItem(at: sourceURL, to: destinationURL)
            }
        }
    }

    private func deleteBackup(_ backup: LocalStoreBackupRecord, in storeDirectory: URL) throws {
        let backupDirectory = storeDirectory.appendingPathComponent(backup.directoryName, isDirectory: true)
        guard fileManager.fileExists(atPath: backupDirectory.path) else {
            return
        }
        try fileManager.removeItem(at: backupDirectory)
    }

    private func bestReadableBackup(
        in manifest: LocalStoreCompatibilityManifest,
        storeDirectory: URL
    ) -> LocalStoreBackupRecord? {
        manifest.backups
            .filter { backup in
                configuration.canReadStoreFormatVersion(backup.storeFormatVersion) &&
                backupStoreExists(backup, in: storeDirectory)
            }
            .sorted {
                if $0.storeFormatVersion != $1.storeFormatVersion {
                    return $0.storeFormatVersion > $1.storeFormatVersion
                }
                return $0.createdAt > $1.createdAt
            }
            .first
    }

    private func backupStoreExists(_ backup: LocalStoreBackupRecord, in storeDirectory: URL) -> Bool {
        let url = storeDirectory
            .appendingPathComponent(backup.directoryName, isDirectory: true)
            .appendingPathComponent(configuration.storeFilename)
        return fileManager.fileExists(atPath: url.path)
    }

    private func uniqueBackupID(in storeDirectory: URL) -> String {
        let baseID = configuration.idProvider()
        var candidate = baseID
        var suffix = 1
        while fileManager.fileExists(
            atPath: storeDirectory
                .appendingPathComponent(configuration.backupsDirectoryName, isDirectory: true)
                .appendingPathComponent(candidate, isDirectory: true)
                .path
        ) {
            candidate = "\(baseID)-\(suffix)"
            suffix += 1
        }
        return candidate
    }

    private var storeFileNames: [String] {
        [
            configuration.storeFilename,
            "\(configuration.storeFilename)-wal",
            "\(configuration.storeFilename)-shm",
        ]
    }

    private func manifestURL(in storeDirectory: URL) -> URL {
        storeDirectory.appendingPathComponent(configuration.manifestFilename)
    }
}

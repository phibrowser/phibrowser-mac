// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import CryptoKit
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
        let storeFileExists = fileManager.fileExists(
            atPath: storeDirectory.appendingPathComponent(configuration.storeFilename).path
        )
        // With no store file there is nothing to back up; SwiftData creates an
        // empty store. This also covers a quarantine interrupted after its
        // files moved but before the manifest recorded it.
        if storeFileExists, configuration.backupPolicy.shouldBackupBeforeOpening(backupContext) {
            let digest = try storeDigest(in: storeDirectory)
            // An open that keeps failing never advances the manifest, so every
            // launch or retry would otherwise copy the same bytes again.
            let alreadyBackedUp = manifestState.manifest.backups.contains { backup in
                backup.storeFormatVersion == manifestState.manifest.activeStoreFormatVersion &&
                    backup.createdBeforeUpgradingToStoreFormatVersion == configuration.currentStoreFormatVersion &&
                    backupStoreExists(backup, in: storeDirectory) &&
                    (try? self.digest(of: backup, in: storeDirectory)) == digest
            }
            if !alreadyBackedUp {
                let backup = try createBackup(
                    forStoreFormatVersion: manifestState.manifest.activeStoreFormatVersion,
                    beforeUpgradingToStoreFormatVersion: configuration.currentStoreFormatVersion,
                    contentDigest: digest,
                    in: storeDirectory
                )
                manifestState.manifest.backups.append(backup)
                createdBackup = backup
            }
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

    /// Moves an active store whose schema matches no known store format out of
    /// the way so the caller can create an empty store in its place.
    ///
    /// The files are moved, never deleted, into a backup that no app version
    /// restores. Earlier backups holding the same bytes were labelled with a
    /// readable format they never had, so they are removed; the quarantine
    /// keeps the only copy. The manifest then records the current format,
    /// which the empty store will have once SwiftData creates it.
    @discardableResult
    func quarantineUnrecognisedStore(at storeDirectory: URL) throws -> LocalStoreBackupRecord {
        var manifestState = try loadManifest(from: storeDirectory)
        let mainStoreURL = storeDirectory.appendingPathComponent(configuration.storeFilename)
        guard fileManager.fileExists(atPath: mainStoreURL.path) else {
            throw LocalStoreCompatibilityError.missingStoreFile(mainStoreURL)
        }
        let digest = try storeDigest(in: storeDirectory)

        let backupID = uniqueBackupID(in: storeDirectory)
        let directoryName = "\(configuration.backupsDirectoryName)/\(backupID)"
        let quarantineDirectory = storeDirectory.appendingPathComponent(directoryName, isDirectory: true)
        try fileManager.createDirectory(at: quarantineDirectory, withIntermediateDirectories: true)
        for fileName in storeFileNames {
            let sourceURL = storeDirectory.appendingPathComponent(fileName)
            guard fileManager.fileExists(atPath: sourceURL.path) else {
                continue
            }
            try fileManager.moveItem(at: sourceURL, to: quarantineDirectory.appendingPathComponent(fileName))
        }

        let record = LocalStoreBackupRecord(
            id: backupID,
            storeFormatVersion: LocalStoreBackupRecord.unrecognisedStoreFormatVersion,
            directoryName: directoryName,
            createdAt: configuration.dateProvider(),
            createdBeforeUpgradingToStoreFormatVersion: configuration.currentStoreFormatVersion,
            contentDigest: digest,
            isQuarantinedUnrecognisedStore: true
        )
        let mislabelledCopies = manifestState.manifest.backups.filter { backup in
            backup.isQuarantinedUnrecognisedStore != true &&
                (try? self.digest(of: backup, in: storeDirectory)) == digest
        }
        manifestState.manifest.backups.removeAll { backup in
            mislabelledCopies.contains { $0.id == backup.id }
        }
        manifestState.manifest.backups.append(record)
        manifestState.manifest.activeStoreFormatVersion = configuration.currentStoreFormatVersion
        try saveManifest(manifestState.manifest, to: storeDirectory)
        for copy in mislabelledCopies {
            try? deleteBackup(copy, in: storeDirectory)
        }
        return record
    }

    private func loadManifest(from storeDirectory: URL) throws -> (manifest: LocalStoreCompatibilityManifest, wasCreated: Bool) {
        let url = manifestURL(in: storeDirectory)
        guard fileManager.fileExists(atPath: url.path) else {
            let existingStoreURL = storeDirectory.appendingPathComponent(configuration.storeFilename)
            let activeStoreFormatVersion = fileManager.fileExists(atPath: existingStoreURL.path)
                ? configuration.legacyStoreFormatVersionForCurrentBundle()
                : configuration.currentStoreFormatVersion
            return (
                LocalStoreCompatibilityManifest(
                    activeStoreFormatVersion: activeStoreFormatVersion,
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
        contentDigest: String,
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
            createdBeforeUpgradingToStoreFormatVersion: targetStoreFormatVersion,
            contentDigest: contentDigest
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

    private func digest(of backup: LocalStoreBackupRecord, in storeDirectory: URL) throws -> String {
        if let contentDigest = backup.contentDigest {
            return contentDigest
        }
        return try storeDigest(
            in: storeDirectory.appendingPathComponent(backup.directoryName, isDirectory: true)
        )
    }

    /// SHA-256 over the main store file and its write-ahead log. The shared
    /// memory index is derived state and is left out, and an empty log hashes
    /// like a missing one because SQLite creates and removes it freely.
    private func storeDigest(in directory: URL) throws -> String {
        var hasher = SHA256()
        for fileName in [configuration.storeFilename, "\(configuration.storeFilename)-wal"] {
            let url = directory.appendingPathComponent(fileName)
            guard fileManager.fileExists(atPath: url.path) else {
                continue
            }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hashedName = false
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                if !hashedName {
                    hasher.update(data: Data(fileName.utf8))
                    hashedName = true
                }
                hasher.update(data: chunk)
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
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

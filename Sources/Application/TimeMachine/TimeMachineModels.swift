// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

enum TimeMachineAppBundleName {
    static let defaultRollbackName = "Phi.app"

    static func isValid(_ name: String) -> Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmedName.isEmpty
            && name == trimmedName
            && name == (name as NSString).lastPathComponent
            && name.hasSuffix(".app")
    }
}

struct TimeMachineRollbackPolicy: Codable, Equatable {
    let backupTriggerBuild: Int
    let backupTriggerVersion: String
    let rollbackVersion: String
    let rollbackBuild: Int
    let rollbackPackageURL: URL
    let rollbackPackageSHA256: String
    let includeChromiumData: Bool
    let rollbackAppBundleName: String?

    init(
        backupTriggerBuild: Int,
        backupTriggerVersion: String,
        rollbackVersion: String,
        rollbackBuild: Int,
        rollbackPackageURL: URL,
        rollbackPackageSHA256: String,
        includeChromiumData: Bool,
        rollbackAppBundleName: String? = nil
    ) {
        self.backupTriggerBuild = backupTriggerBuild
        self.backupTriggerVersion = backupTriggerVersion
        self.rollbackVersion = rollbackVersion
        self.rollbackBuild = rollbackBuild
        self.rollbackPackageURL = rollbackPackageURL
        self.rollbackPackageSHA256 = rollbackPackageSHA256
        self.includeChromiumData = includeChromiumData
        self.rollbackAppBundleName = rollbackAppBundleName
    }

    func shouldCreateBackup(
        currentVersion: String,
        currentBuild: Int,
        triggerMode: TimeMachineBackupTriggerMode = .current
    ) -> Bool {
        switch triggerMode {
        case .build:
            return currentBuild == backupTriggerBuild
        case .version:
            return currentVersion == backupTriggerVersion
        }
    }
}

enum TimeMachineBackupTriggerMode: Equatable {
    case build
    case version

    static var current: TimeMachineBackupTriggerMode {
        #if NIGHTLY_BUILD
        return .build
        #else
        return .version
        #endif
    }
}

struct TimeMachineCatalog: Codable, Equatable {
    var backups: [TimeMachineBackupRecord]
    var suppressedBackupTriggers: [TimeMachineSuppressedBackupTrigger]

    init(
        backups: [TimeMachineBackupRecord] = [],
        suppressedBackupTriggers: [TimeMachineSuppressedBackupTrigger] = []
    ) {
        self.backups = backups
        self.suppressedBackupTriggers = suppressedBackupTriggers
    }

    var completedBackups: [TimeMachineBackupRecord] {
        backups
            .filter { $0.status == .completed }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func hasCompletedBackup(triggerBuild: Int) -> Bool {
        completedBackups.contains { $0.backupTriggerBuild == triggerBuild }
    }

    func hasCompletedBackup(creatingVersion: String) -> Bool {
        completedBackups.contains { $0.creatingVersion == creatingVersion }
    }

    func hasHandledBackup(triggerBuild: Int) -> Bool {
        hasCompletedBackup(triggerBuild: triggerBuild)
            || suppressedBackupTriggers.contains { $0.backupTriggerBuild == triggerBuild }
    }

    func hasHandledBackup(creatingVersion: String) -> Bool {
        hasCompletedBackup(creatingVersion: creatingVersion)
            || suppressedBackupTriggers.contains { $0.creatingVersion == creatingVersion }
    }

    private enum CodingKeys: String, CodingKey {
        case backups
        case suppressedBackupTriggers
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        backups = try container.decodeIfPresent([TimeMachineBackupRecord].self, forKey: .backups) ?? []
        suppressedBackupTriggers = try container.decodeIfPresent(
            [TimeMachineSuppressedBackupTrigger].self,
            forKey: .suppressedBackupTriggers
        ) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(backups, forKey: .backups)
        if !suppressedBackupTriggers.isEmpty {
            try container.encode(suppressedBackupTriggers, forKey: .suppressedBackupTriggers)
        }
    }
}

struct TimeMachineSuppressedBackupTrigger: Codable, Equatable {
    let backupTriggerBuild: Int
    let creatingVersion: String
}

struct TimeMachineBackupRecord: Codable, Equatable, Identifiable {
    let id: UUID
    let createdAt: Date
    let creatingVersion: String
    let creatingBuild: Int
    let backupTriggerBuild: Int
    let rollbackVersion: String
    let rollbackBuild: Int
    let rollbackPackageURL: URL
    let rollbackPackageSHA256: String
    let includeChromiumData: Bool
    let snapshotRelativePath: String
    var snapshotSizeBytes: UInt64?
    let status: Status
    let rollbackAppBundleName: String?

    enum Status: String, Codable {
        case completed
    }

    init(
        id: UUID,
        createdAt: Date,
        creatingVersion: String,
        creatingBuild: Int,
        backupTriggerBuild: Int,
        rollbackVersion: String,
        rollbackBuild: Int,
        rollbackPackageURL: URL,
        rollbackPackageSHA256: String,
        includeChromiumData: Bool,
        snapshotRelativePath: String,
        snapshotSizeBytes: UInt64? = nil,
        status: Status,
        rollbackAppBundleName: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.creatingVersion = creatingVersion
        self.creatingBuild = creatingBuild
        self.backupTriggerBuild = backupTriggerBuild
        self.rollbackVersion = rollbackVersion
        self.rollbackBuild = rollbackBuild
        self.rollbackPackageURL = rollbackPackageURL
        self.rollbackPackageSHA256 = rollbackPackageSHA256
        self.includeChromiumData = includeChromiumData
        self.snapshotRelativePath = snapshotRelativePath
        self.snapshotSizeBytes = snapshotSizeBytes
        self.status = status
        self.rollbackAppBundleName = rollbackAppBundleName
    }

    func menuTitle(timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy.M.d"
        return "Phi \(rollbackVersion) (\(rollbackBuild)) on \(formatter.string(from: createdAt))"
    }
}

struct TimeMachineSnapshotManifest: Codable, Equatable, Identifiable {
    static let filename = "manifest.json"

    let id: UUID
    let createdAt: Date
    let creatingVersion: String
    let creatingBuild: Int
    let backupTriggerBuild: Int
    let rollbackVersion: String
    let rollbackBuild: Int
    let rollbackPackageURL: URL
    let rollbackPackageSHA256: String
    let includeChromiumData: Bool
    let applicationSupportRelativePath: String?
    let phiDataRelativePath: String?
    let preferencesRelativePath: String?
    let rollbackAppBundleName: String?

    init(
        id: UUID,
        createdAt: Date,
        creatingVersion: String,
        creatingBuild: Int,
        backupTriggerBuild: Int,
        rollbackVersion: String,
        rollbackBuild: Int,
        rollbackPackageURL: URL,
        rollbackPackageSHA256: String,
        includeChromiumData: Bool,
        applicationSupportRelativePath: String?,
        phiDataRelativePath: String?,
        preferencesRelativePath: String?,
        rollbackAppBundleName: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.creatingVersion = creatingVersion
        self.creatingBuild = creatingBuild
        self.backupTriggerBuild = backupTriggerBuild
        self.rollbackVersion = rollbackVersion
        self.rollbackBuild = rollbackBuild
        self.rollbackPackageURL = rollbackPackageURL
        self.rollbackPackageSHA256 = rollbackPackageSHA256
        self.includeChromiumData = includeChromiumData
        self.applicationSupportRelativePath = applicationSupportRelativePath
        self.phiDataRelativePath = phiDataRelativePath
        self.preferencesRelativePath = preferencesRelativePath
        self.rollbackAppBundleName = rollbackAppBundleName
    }
}

struct TimeMachineInstallPlan: Codable, Equatable {
    let operationID: UUID
    let backupID: UUID?
    let hostPID: Int32
    let bundleIdentifier: String
    let currentAppURL: URL
    let stagedAppURL: URL
    let snapshotURL: URL?
    let currentApplicationSupportURL: URL
    let snapshotApplicationSupportURL: URL?
    let currentPhiDataURL: URL
    let snapshotPhiDataURL: URL?
    let currentPreferencesURL: URL
    let snapshotPreferencesURL: URL?
    let emergencyBackupURL: URL
    let includeChromiumData: Bool
    let rollbackVersion: String
    let rollbackBuild: Int
    let packageSHA256: String

    init(
        operationID: UUID,
        backupID: UUID? = nil,
        hostPID: Int32,
        bundleIdentifier: String,
        currentAppURL: URL,
        stagedAppURL: URL,
        snapshotURL: URL? = nil,
        currentApplicationSupportURL: URL,
        snapshotApplicationSupportURL: URL?,
        currentPhiDataURL: URL,
        snapshotPhiDataURL: URL?,
        currentPreferencesURL: URL,
        snapshotPreferencesURL: URL?,
        emergencyBackupURL: URL,
        includeChromiumData: Bool,
        rollbackVersion: String,
        rollbackBuild: Int,
        packageSHA256: String
    ) {
        self.operationID = operationID
        self.backupID = backupID
        self.hostPID = hostPID
        self.bundleIdentifier = bundleIdentifier
        self.currentAppURL = currentAppURL
        self.stagedAppURL = stagedAppURL
        self.snapshotURL = snapshotURL
        self.currentApplicationSupportURL = currentApplicationSupportURL
        self.snapshotApplicationSupportURL = snapshotApplicationSupportURL
        self.currentPhiDataURL = currentPhiDataURL
        self.snapshotPhiDataURL = snapshotPhiDataURL
        self.currentPreferencesURL = currentPreferencesURL
        self.snapshotPreferencesURL = snapshotPreferencesURL
        self.emergencyBackupURL = emergencyBackupURL
        self.includeChromiumData = includeChromiumData
        self.rollbackVersion = rollbackVersion
        self.rollbackBuild = rollbackBuild
        self.packageSHA256 = packageSHA256
    }
}

enum TimeMachineRestorePreparationStage: String, Codable, CaseIterable {
    case preparing
    case downloadingPackage
    case expandingPackage
    case validatingPackage
    case preparingInstaller
    case launchingInstaller
    case readyToQuit
}

struct TimeMachineRestorePreparationProgress: Equatable {
    let stage: TimeMachineRestorePreparationStage
    let fractionCompleted: Double?

    init(stage: TimeMachineRestorePreparationStage, fractionCompleted: Double?) {
        self.stage = stage
        self.fractionCompleted = fractionCompleted.map { min(max($0, 0), 1) }
    }
}

struct TimeMachineBackupTrace: Codable, Equatable {
    enum Result: String, Codable {
        case succeeded
        case failed
    }

    let result: Result
    let backupID: UUID
    let bundleIdentifier: String
    let currentVersion: String
    let currentBuild: Int
    let backupTriggerBuild: Int
    let rollbackVersion: String
    let rollbackBuild: Int
    let includeChromiumData: Bool
    let duration: TimeInterval
    let snapshotSizeBytes: UInt64?
    let errorDescription: String?
    let errorType: String?
}

struct TimeMachineRestorePreparationTrace: Codable, Equatable {
    enum Result: String, Codable {
        case succeeded
        case failed
    }

    let result: Result
    let operationID: UUID
    let backupID: UUID
    let bundleIdentifier: String
    let rollbackVersion: String
    let rollbackBuild: Int
    let includeChromiumData: Bool
    let duration: TimeInterval
    let lastStage: TimeMachineRestorePreparationStage
    let packageSizeBytes: UInt64?
    let operationSizeBytes: UInt64?
    let errorDescription: String?
    let errorType: String?
}

struct TimeMachineRestoreRecoveryTrace: Codable, Equatable {
    enum Status: String, Codable {
        case launched
        case blocked
        case markedFailed
        case inspectionFailed
    }

    let status: Status
    let operationID: UUID?
    let bundleIdentifier: String
    let phase: TimeMachineRestorePhase?
    let hasStartedDestructiveSwap: Bool?
    let reason: String?
    let errorDescription: String?
    let errorType: String?
}

enum TimeMachineRestorePhase: String, Codable, CaseIterable {
    case prepared
    case dataStaged
    case dataBackedUp
    case dataSwapStarted
    case dataSwapped
    case appBackedUp
    case appSwapStarted
    case appSwapped
    case completed
    case failed
    case reverted

    var needsRecovery: Bool {
        switch self {
        case .completed, .failed, .reverted:
            return false
        case .prepared, .dataStaged, .dataBackedUp, .dataSwapStarted, .dataSwapped, .appBackedUp, .appSwapStarted, .appSwapped:
            return true
        }
    }

    var hasStartedDestructiveSwap: Bool {
        switch self {
        case .dataSwapStarted, .dataSwapped, .appBackedUp, .appSwapStarted, .appSwapped:
            return true
        case .prepared, .dataStaged, .dataBackedUp, .completed, .failed, .reverted:
            return false
        }
    }
}

struct TimeMachineRestoreJournal: Codable, Equatable {
    let operationID: UUID
    var phase: TimeMachineRestorePhase
    var updatedAt: Date
    let planRelativePath: String
    let helperRelativePath: String
}

enum TimeMachineFileMetrics {
    static func sizeBytes(at url: URL, fileManager: FileManager = .default) -> UInt64? {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return nil
        }

        if !isDirectory.boolValue {
            return fileSizeBytes(at: url, fileManager: fileManager)
        }

        let resourceKeys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey]
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: resourceKeys,
            options: [],
            errorHandler: nil
        ) else {
            return nil
        }

        var total: UInt64 = 0
        for case let itemURL as URL in enumerator {
            guard let values = try? itemURL.resourceValues(forKeys: Set(resourceKeys)) else {
                continue
            }
            if values.isDirectory == true {
                continue
            }
            if values.isRegularFile == true || values.fileSize != nil {
                total += UInt64(max(values.fileSize ?? 0, 0))
            }
        }
        return total
    }

    private static func fileSizeBytes(at url: URL, fileManager: FileManager) -> UInt64? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else {
            return nil
        }
        return size.uint64Value
    }
}

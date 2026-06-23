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
    let rollbackVersion: String
    let rollbackBuild: Int
    let rollbackPackageURL: URL
    let rollbackPackageSHA256: String
    let includeChromiumData: Bool
    let rollbackAppBundleName: String?

    init(
        backupTriggerBuild: Int,
        rollbackVersion: String,
        rollbackBuild: Int,
        rollbackPackageURL: URL,
        rollbackPackageSHA256: String,
        includeChromiumData: Bool,
        rollbackAppBundleName: String? = nil
    ) {
        self.backupTriggerBuild = backupTriggerBuild
        self.rollbackVersion = rollbackVersion
        self.rollbackBuild = rollbackBuild
        self.rollbackPackageURL = rollbackPackageURL
        self.rollbackPackageSHA256 = rollbackPackageSHA256
        self.includeChromiumData = includeChromiumData
        self.rollbackAppBundleName = rollbackAppBundleName
    }

    func shouldCreateBackup(forBuild build: Int) -> Bool {
        build == backupTriggerBuild
    }
}

struct TimeMachineCatalog: Codable, Equatable {
    var backups: [TimeMachineBackupRecord]

    init(backups: [TimeMachineBackupRecord] = []) {
        self.backups = backups
    }

    var completedBackups: [TimeMachineBackupRecord] {
        backups
            .filter { $0.status == .completed }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func hasCompletedBackup(triggerBuild: Int) -> Bool {
        completedBackups.contains { $0.backupTriggerBuild == triggerBuild }
    }
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

enum TimeMachineRestorePreparationStage: String, CaseIterable {
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

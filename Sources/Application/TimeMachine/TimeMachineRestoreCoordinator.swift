// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

enum TimeMachineRestoreCoordinatorError: Error, LocalizedError {
    case missingSnapshot(URL)
    case missingStagedApp(URL)
    case missingHelper
    case invalidStagedAppBundleName(String?)
    case invalidBundleIdentifier(expected: String, actual: String?)
    case invalidBundleVersion(expected: Int, actual: String?)
    case processFailed(executable: URL, status: Int32, output: String)

    var errorDescription: String? {
        switch self {
        case .missingSnapshot(let url):
            return "Missing Time Machine snapshot at \(url.path)."
        case .missingStagedApp(let url):
            return "Missing staged rollback app at \(url.path)."
        case .missingHelper:
            return "Time Machine installer helper is unavailable."
        case .invalidStagedAppBundleName(let name):
            return "Invalid rollback app bundle name \(name ?? "nil")."
        case .invalidBundleIdentifier(let expected, let actual):
            return "Invalid rollback app bundle identifier. Expected \(expected), got \(actual ?? "nil")."
        case .invalidBundleVersion(let expected, let actual):
            return "Invalid rollback app build. Expected \(expected), got \(actual ?? "nil")."
        case .processFailed(let executable, let status, let output):
            return "\(executable.path) failed with status \(status): \(output)"
        }
    }
}

struct TimeMachineRestoreCoordinator {
    typealias PackageDownloader = (URL, String, URL) async throws -> URL
    typealias ProcessRunner = (URL, [String]) throws -> Void
    typealias ProgressHandler = (TimeMachineRestorePreparationProgress) -> Void

    static let packageFilename = "package.zip"
    static let extractedPackageDirectoryName = "Package"
    static let installPlanFilename = "install-plan.json"
    static let helperFilename = "PhiTimeMachineInstaller"

    private let paths: TimeMachinePaths
    private let packageDownloader: PackageDownloader
    private let unzipRunner: ProcessRunner
    private let helperLauncher: ProcessRunner
    private let helperURLProvider: () -> URL?
    private let currentAppURLProvider: () -> URL
    private let applicationSupportURLProvider: () -> URL
    private let phiDataURLProvider: () -> URL
    private let preferencesURLProvider: () -> URL
    private let operationIDProvider: () -> UUID
    private let hostPIDProvider: () -> Int32
    private let fileCloner: TimeMachineFileCloner
    private let journalStore: TimeMachineRestoreJournalStore
    private let progressHandler: ProgressHandler?
    private let fileManager: FileManager

    init(
        paths: TimeMachinePaths = TimeMachinePaths(),
        packageDownloader: PackageDownloader? = nil,
        unzipRunner: @escaping ProcessRunner = Self.runUnzip,
        helperLauncher: @escaping ProcessRunner = Self.launchProcess,
        helperURLProvider: @escaping () -> URL? = {
            Self.bundledHelperURL()
        },
        currentAppURLProvider: @escaping () -> URL = {
            Bundle.main.bundleURL
        },
        applicationSupportURLProvider: @escaping () -> URL = {
            URL(fileURLWithPath: FileSystemUtils.applicationSupportDirctory(), isDirectory: true)
        },
        phiDataURLProvider: @escaping () -> URL = {
            URL(fileURLWithPath: FileSystemUtils.phiBrowserDataDirectory(), isDirectory: true)
        },
        preferencesURLProvider: @escaping () -> URL = {
            URL(fileURLWithPath: FileSystemUtils.plistPath(), isDirectory: false)
        },
        operationIDProvider: @escaping () -> UUID = UUID.init,
        hostPIDProvider: @escaping () -> Int32 = { ProcessInfo.processInfo.processIdentifier },
        fileCloner: TimeMachineFileCloner = TimeMachineFileCloner(),
        journalStore: TimeMachineRestoreJournalStore? = nil,
        progressHandler: ProgressHandler? = nil,
        fileManager: FileManager = .default
    ) {
        self.paths = paths
        self.packageDownloader = packageDownloader ?? { sourceURL, expectedSHA256, destinationURL in
            try await TimeMachinePackageDownloader().downloadPackage(
                from: sourceURL,
                expectedSHA256: expectedSHA256,
                to: destinationURL
            )
        }
        self.unzipRunner = unzipRunner
        self.helperLauncher = helperLauncher
        self.helperURLProvider = helperURLProvider
        self.currentAppURLProvider = currentAppURLProvider
        self.applicationSupportURLProvider = applicationSupportURLProvider
        self.phiDataURLProvider = phiDataURLProvider
        self.preferencesURLProvider = preferencesURLProvider
        self.operationIDProvider = operationIDProvider
        self.hostPIDProvider = hostPIDProvider
        self.fileCloner = fileCloner
        self.journalStore = journalStore ?? TimeMachineRestoreJournalStore(paths: paths)
        self.progressHandler = progressHandler
        self.fileManager = fileManager
    }

    @discardableResult
    func prepareAndLaunchRestore(for backup: TimeMachineBackupRecord) async throws -> TimeMachineInstallPlan {
        let operationID = operationIDProvider()
        let operationURL = paths.pendingOperationURL(id: operationID)
        let packageURL = operationURL.appendingPathComponent(Self.packageFilename, isDirectory: false)
        let extractedPackageURL = operationURL.appendingPathComponent(Self.extractedPackageDirectoryName, isDirectory: true)
        let planURL = operationURL.appendingPathComponent(Self.installPlanFilename, isDirectory: false)
        var wroteJournal = false

        AppLogInfo(
            "[TimeMachine] Preparing restore operation=\(operationID.uuidString) backup=\(backup.id.uuidString) " +
            "rollback=\(backup.rollbackVersion) build=\(backup.rollbackBuild) scope=\(scopeDescription(backup.includeChromiumData)) " +
            "bundle=\(paths.bundleIdentifier)"
        )
        reportProgress(stage: .preparing, fractionCompleted: 0.02)
        do {
            if fileManager.fileExists(atPath: operationURL.path) {
                AppLogInfo("[TimeMachine] Removing stale restore operation directory at \(operationURL.path).")
                try fileManager.removeItem(at: operationURL)
            }
            try fileManager.createDirectory(at: operationURL, withIntermediateDirectories: true)
            AppLogInfo("[TimeMachine] Restore operation directory created at \(operationURL.path).")

            AppLogInfo("[TimeMachine] Downloading rollback package from \(backup.rollbackPackageURL.absoluteString).")
            reportProgress(stage: .downloadingPackage, fractionCompleted: nil)
            _ = try await packageDownloader(backup.rollbackPackageURL, backup.rollbackPackageSHA256, packageURL)
            AppLogInfo("[TimeMachine] Rollback package downloaded and SHA-256 verified at \(packageURL.path).")
            try fileManager.createDirectory(at: extractedPackageURL, withIntermediateDirectories: true)
            AppLogInfo("[TimeMachine] Expanding rollback package into \(extractedPackageURL.path).")
            reportProgress(stage: .expandingPackage, fractionCompleted: 0.55)
            try unzipRunner(packageURL, ["-q", packageURL.path, "-d", extractedPackageURL.path])
            AppLogInfo("[TimeMachine] Rollback package expanded.")

            let stagedAppURL = try stagedAppURL(in: extractedPackageURL, backup: backup)
            AppLogInfo("[TimeMachine] Validating staged rollback app at \(stagedAppURL.path).")
            reportProgress(stage: .validatingPackage, fractionCompleted: 0.72)
            try validateStagedApp(stagedAppURL, backup: backup)
            AppLogInfo("[TimeMachine] Staged rollback app validated for bundle \(paths.bundleIdentifier) build \(backup.rollbackBuild).")

            reportProgress(stage: .preparingInstaller, fractionCompleted: 0.84)
            let helperURL = try copyHelper(to: operationURL)
            AppLogInfo("[TimeMachine] Installer helper copied to \(helperURL.path).")
            let plan = try makeInstallPlan(
                operationID: operationID,
                backup: backup,
                stagedAppURL: stagedAppURL
            )
            try writePlan(plan, to: planURL)
            AppLogInfo("[TimeMachine] Restore install plan written to \(planURL.path).")
            try journalStore.write(
                TimeMachineRestoreJournal(
                    operationID: operationID,
                    phase: .prepared,
                    updatedAt: Date(),
                    planRelativePath: paths.relativePath(for: planURL),
                    helperRelativePath: paths.relativePath(for: helperURL)
                )
            )
            wroteJournal = true
            AppLogInfo("[TimeMachine] Restore journal prepared for operation \(operationID.uuidString).")
            reportProgress(stage: .launchingInstaller, fractionCompleted: 0.95)
            try helperLauncher(helperURL, Self.helperArguments(planURL: planURL))
            AppLogInfo("[TimeMachine] Installer helper launched for operation \(operationID.uuidString).")
            reportProgress(stage: .readyToQuit, fractionCompleted: 1)
            return plan
        } catch {
            AppLogError("[TimeMachine] Failed to prepare restore operation \(operationID.uuidString): \(error.localizedDescription)")
            if !wroteJournal {
                AppLogInfo("[TimeMachine] Cleaning failed restore operation directory at \(operationURL.path).")
                try? fileManager.removeItem(at: operationURL)
            }
            throw error
        }
    }

    static func helperArguments(planURL: URL) -> [String] {
        ["--plan", planURL.path]
    }

    static func bundledHelperURL(
        in bundle: Bundle = .main,
        fileManager: FileManager = .default
    ) -> URL? {
        if let auxiliaryURL = bundle.url(forAuxiliaryExecutable: helperFilename),
           fileManager.isExecutableFile(atPath: auxiliaryURL.path) {
            return auxiliaryURL
        }

        let helpersURL = bundle.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent(helperFilename, isDirectory: false)
        guard fileManager.isExecutableFile(atPath: helpersURL.path) else {
            return nil
        }
        return helpersURL
    }

    private func stagedAppURL(in extractedPackageURL: URL, backup: TimeMachineBackupRecord) throws -> URL {
        let appBundleName = try rollbackAppBundleName(for: backup)
        AppLogInfo("[TimeMachine] Expecting rollback app bundle named \(appBundleName).")
        return extractedPackageURL.appendingPathComponent(appBundleName, isDirectory: true)
    }

    private func rollbackAppBundleName(for backup: TimeMachineBackupRecord) throws -> String {
        if let configuredName = backup.rollbackAppBundleName {
            guard TimeMachineAppBundleName.isValid(configuredName) else {
                throw TimeMachineRestoreCoordinatorError.invalidStagedAppBundleName(configuredName)
            }
            return configuredName
        }

        let inferredName = currentAppURLProvider().lastPathComponent
        guard TimeMachineAppBundleName.isValid(inferredName) else {
            throw TimeMachineRestoreCoordinatorError.invalidStagedAppBundleName(inferredName)
        }
        AppLogInfo("[TimeMachine] Backup record has no rollback app bundle name; inferred \(inferredName) from current app.")
        return inferredName
    }

    private func validateStagedApp(_ appURL: URL, backup: TimeMachineBackupRecord) throws {
        guard fileManager.fileExists(atPath: appURL.path) else {
            throw TimeMachineRestoreCoordinatorError.missingStagedApp(appURL)
        }

        let infoURL = appURL.appendingPathComponent("Contents/Info.plist", isDirectory: false)
        let info = NSDictionary(contentsOf: infoURL) as? [String: Any]
        let bundleIdentifier = info?["CFBundleIdentifier"] as? String
        guard bundleIdentifier == paths.bundleIdentifier else {
            throw TimeMachineRestoreCoordinatorError.invalidBundleIdentifier(
                expected: paths.bundleIdentifier,
                actual: bundleIdentifier
            )
        }

        let bundleVersion = info?["CFBundleVersion"] as? String
        guard bundleVersion == String(backup.rollbackBuild) else {
            throw TimeMachineRestoreCoordinatorError.invalidBundleVersion(
                expected: backup.rollbackBuild,
                actual: bundleVersion
            )
        }
    }

    private func copyHelper(to operationURL: URL) throws -> URL {
        guard let sourceURL = helperURLProvider() else {
            throw TimeMachineRestoreCoordinatorError.missingHelper
        }

        let destinationURL = operationURL.appendingPathComponent(Self.helperFilename, isDirectory: false)
        if fileManager.fileExists(atPath: destinationURL.path) {
            AppLogInfo("[TimeMachine] Removing stale copied helper at \(destinationURL.path).")
            try fileManager.removeItem(at: destinationURL)
        }
        try fileCloner.copyItem(at: sourceURL, to: destinationURL)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destinationURL.path)
        return destinationURL
    }

    private func makeInstallPlan(
        operationID: UUID,
        backup: TimeMachineBackupRecord,
        stagedAppURL: URL
    ) throws -> TimeMachineInstallPlan {
        let snapshotURL = paths.url(forRelativePath: backup.snapshotRelativePath)
        guard fileManager.fileExists(atPath: snapshotURL.path) else {
            AppLogError("[TimeMachine] Restore snapshot is missing at \(snapshotURL.path).")
            throw TimeMachineRestoreCoordinatorError.missingSnapshot(snapshotURL)
        }

        let snapshotApplicationSupportURL = backup.includeChromiumData
            ? snapshotURL
                .appendingPathComponent("ApplicationSupport", isDirectory: true)
                .appendingPathComponent(paths.bundleIdentifier, isDirectory: true)
            : nil
        let snapshotPhiDataURL = snapshotURL
            .appendingPathComponent("ApplicationSupport", isDirectory: true)
            .appendingPathComponent(paths.bundleIdentifier, isDirectory: true)
            .appendingPathComponent("Phi", isDirectory: true)
        let snapshotPreferencesURL = snapshotURL
            .appendingPathComponent("Preferences", isDirectory: true)
            .appendingPathComponent("\(paths.bundleIdentifier).plist", isDirectory: false)
        let requiredSnapshotURL = backup.includeChromiumData
            ? snapshotApplicationSupportURL
            : snapshotPhiDataURL
        guard let requiredSnapshotURL, fileManager.fileExists(atPath: requiredSnapshotURL.path) else {
            AppLogError("[TimeMachine] Required restore snapshot item is missing at \((requiredSnapshotURL ?? snapshotURL).path).")
            throw TimeMachineRestoreCoordinatorError.missingSnapshot(requiredSnapshotURL ?? snapshotURL)
        }
        AppLogInfo(
            "[TimeMachine] Restore snapshot resolved at \(snapshotURL.path); " +
            "applicationSupport=\(snapshotApplicationSupportURL?.path ?? "nil") phi=\(snapshotPhiDataURL.path) " +
            "preferences=\(snapshotPreferencesURL.path)"
        )

        return TimeMachineInstallPlan(
            operationID: operationID,
            backupID: backup.id,
            hostPID: hostPIDProvider(),
            bundleIdentifier: paths.bundleIdentifier,
            currentAppURL: currentAppURLProvider(),
            stagedAppURL: stagedAppURL,
            snapshotURL: snapshotURL,
            currentApplicationSupportURL: applicationSupportURLProvider(),
            snapshotApplicationSupportURL: existingURL(snapshotApplicationSupportURL),
            currentPhiDataURL: phiDataURLProvider(),
            snapshotPhiDataURL: existingURL(snapshotPhiDataURL),
            currentPreferencesURL: preferencesURLProvider(),
            snapshotPreferencesURL: existingURL(snapshotPreferencesURL),
            emergencyBackupURL: paths.emergencyOperationURL(id: operationID),
            includeChromiumData: backup.includeChromiumData,
            rollbackVersion: backup.rollbackVersion,
            rollbackBuild: backup.rollbackBuild,
            packageSHA256: backup.rollbackPackageSHA256
        )
    }

    private func existingURL(_ url: URL?) -> URL? {
        guard let url, fileManager.fileExists(atPath: url.path) else {
            return nil
        }
        return url
    }

    private func writePlan(_ plan: TimeMachineInstallPlan, to planURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(plan)
        try data.write(to: planURL, options: .atomic)
    }

    private static func runUnzip(archiveURL _: URL, arguments: [String]) throws {
        try runAndWait(executableURL: URL(fileURLWithPath: "/usr/bin/unzip"), arguments: arguments)
    }

    private static func launchProcess(executableURL: URL, arguments: [String]) throws {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        try process.run()
    }

    private static func runAndWait(executableURL: URL, arguments: [String]) throws {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            throw TimeMachineRestoreCoordinatorError.processFailed(
                executable: executableURL,
                status: process.terminationStatus,
                output: output
            )
        }
    }

    private func scopeDescription(_ includeChromiumData: Bool) -> String {
        includeChromiumData ? "full" : "phi-only"
    }

    private func reportProgress(stage: TimeMachineRestorePreparationStage, fractionCompleted: Double?) {
        progressHandler?(
            TimeMachineRestorePreparationProgress(
                stage: stage,
                fractionCompleted: fractionCompleted
            )
        )
    }
}

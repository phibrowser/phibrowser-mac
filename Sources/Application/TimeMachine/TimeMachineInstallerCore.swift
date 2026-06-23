// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Darwin
import AppKit
import Foundation

enum TimeMachineInstallerCoreError: Error, LocalizedError {
    case missingPlan(URL)
    case missingJournal(UUID)
    case missingRequiredSnapshot(URL)
    case missingStagedApp(URL)
    case hostProcessDidNotExit(Int32)

    var errorDescription: String? {
        switch self {
        case .missingPlan(let url):
            return "Missing Time Machine install plan at \(url.path)."
        case .missingJournal(let operationID):
            return "Missing Time Machine restore journal for \(operationID.uuidString)."
        case .missingRequiredSnapshot(let url):
            return "Missing Time Machine snapshot item at \(url.path)."
        case .missingStagedApp(let url):
            return "Missing Time Machine staged app at \(url.path)."
        case .hostProcessDidNotExit(let pid):
            return "Phi host process \(pid) did not exit before restore."
        }
    }
}

struct TimeMachineInstallerCore {
    typealias HostWaiter = (Int32) throws -> Void
    typealias SentinelTerminator = (String) throws -> Void
    typealias AppOpener = (URL) throws -> Void
    typealias PhaseObserver = (TimeMachineRestorePhase) throws -> Void
    typealias Logger = (String) -> Void

    private static let dataStagingDirectoryName = "DataStaging"
    private static let applicationSupportStageName = "ApplicationSupport"
    private static let phiStageName = "Phi"
    private static let preferencesStageName = "Preferences"
    private static let appBackupDirectoryName = "App"
    private static let dataBackupDirectoryName = "Data"
    private static let installerLogFilename = "installer.log"

    private let paths: TimeMachinePaths
    private let journalStore: TimeMachineRestoreJournalStore
    private let completedRestoreCleaner: TimeMachineCompletedRestoreCleaner
    private let fileCloner: TimeMachineFileCloner
    private let fileManager: FileManager
    private let hostWaiter: HostWaiter
    private let sentinelTerminator: SentinelTerminator
    private let appOpener: AppOpener
    private let dateProvider: () -> Date
    private let phaseObserver: PhaseObserver
    private let logger: Logger

    init(
        paths: TimeMachinePaths,
        journalStore: TimeMachineRestoreJournalStore? = nil,
        catalogStore: TimeMachineCatalogStore? = nil,
        fileCloner: TimeMachineFileCloner = TimeMachineFileCloner(),
        fileManager: FileManager = .default,
        hostWaiter: @escaping HostWaiter = Self.waitForHostExit,
        sentinelTerminator: @escaping SentinelTerminator = Self.terminateSentinelBestEffort,
        appOpener: @escaping AppOpener = Self.openApp,
        dateProvider: @escaping () -> Date = Date.init,
        phaseObserver: @escaping PhaseObserver = { _ in },
        logger: @escaping Logger = Self.logToStandardError
    ) {
        self.paths = paths
        self.journalStore = journalStore ?? TimeMachineRestoreJournalStore(paths: paths)
        self.completedRestoreCleaner = TimeMachineCompletedRestoreCleaner(
            paths: paths,
            catalogStore: catalogStore ?? TimeMachineCatalogStore(paths: paths, fileManager: fileManager),
            fileManager: fileManager
        )
        self.fileCloner = fileCloner
        self.fileManager = fileManager
        self.hostWaiter = hostWaiter
        self.sentinelTerminator = sentinelTerminator
        self.appOpener = appOpener
        self.dateProvider = dateProvider
        self.phaseObserver = phaseObserver
        self.logger = logger
    }

    func restore(planURL: URL) throws {
        logger("[TimeMachineInstaller] Restore requested with plan \(planURL.path).")
        let plan = try Self.loadPlan(at: planURL, fileManager: fileManager)
        guard var journal = try journalStore.load(operationID: plan.operationID) else {
            throw TimeMachineInstallerCoreError.missingJournal(plan.operationID)
        }
        var context = RestoreContext(plan: plan, journal: journal, paths: paths)
        log("Loaded restore plan for operation \(plan.operationID.uuidString); current phase=\(journal.phase.rawValue).", context: context)
        try run(context: &context)
    }

    func recover(operationID: UUID) throws {
        logger("[TimeMachineInstaller] Recovery requested for operation \(operationID.uuidString).")
        guard var journal = try journalStore.load(operationID: operationID) else {
            throw TimeMachineInstallerCoreError.missingJournal(operationID)
        }
        let planURL = paths.url(forRelativePath: journal.planRelativePath)
        let plan = try Self.loadPlan(at: planURL, fileManager: fileManager)
        var context = RestoreContext(plan: plan, journal: journal, paths: paths)
        log("Loaded recovery plan from \(planURL.path); current phase=\(journal.phase.rawValue).", context: context)
        try run(context: &context)
    }

    static func loadPlan(at planURL: URL, fileManager: FileManager = .default) throws -> TimeMachineInstallPlan {
        guard fileManager.fileExists(atPath: planURL.path) else {
            throw TimeMachineInstallerCoreError.missingPlan(planURL)
        }
        let data = try Data(contentsOf: planURL)
        return try JSONDecoder().decode(TimeMachineInstallPlan.self, from: data)
    }

    static func inferredRootURL(planURL: URL) -> URL {
        planURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func run(context: inout RestoreContext) throws {
        log(
            "Starting restore transaction rollback=\(context.plan.rollbackVersion) build=\(context.plan.rollbackBuild) " +
            "scope=\(scopeDescription(context.plan.includeChromiumData)) bundle=\(context.plan.bundleIdentifier).",
            context: context
        )
        do {
            while context.journal.phase.needsRecovery {
                log("Running phase \(context.journal.phase.rawValue).", context: context)
                switch context.journal.phase {
                case .prepared:
                    log("Waiting for host pid \(context.plan.hostPID) to exit.", context: context)
                    try hostWaiter(context.plan.hostPID)
                    log("Host process has exited.", context: context)
                    terminateSentinel(context: context)
                    try stageData(context: context)
                    try advancePhase(.dataStaged, context: &context)
                case .dataStaged:
                    terminateSentinel(context: context)
                    try backupData(context: context)
                    try advancePhase(.dataBackedUp, context: &context)
                case .dataBackedUp:
                    terminateSentinel(context: context)
                    try advancePhase(.dataSwapStarted, context: &context)
                case .dataSwapStarted:
                    try swapData(context: context)
                    try advancePhase(.dataSwapped, context: &context)
                case .dataSwapped:
                    try backupApp(context: context)
                    try advancePhase(.appBackedUp, context: &context)
                case .appBackedUp:
                    try advancePhase(.appSwapStarted, context: &context)
                case .appSwapStarted:
                    try swapApp(context: context)
                    try advancePhase(.appSwapped, context: &context)
                case .appSwapped:
                    try advancePhase(.completed, context: &context)
                    log("Restore operation completed; removing restore artifacts.", context: context)
                    cleanupCompletedRestoreArtifacts(context: context)
                    logger("[TimeMachineInstaller] Restore operation completed; opening app at \(context.plan.currentAppURL.path).")
                    try? appOpener(context.plan.currentAppURL)
                case .completed, .failed, .reverted:
                    return
                }
            }
        } catch {
            log("Restore transaction failed in phase \(context.journal.phase.rawValue): \(error.localizedDescription)", context: context)
            try handleFailure(context: &context)
            throw error
        }
    }

    private func terminateSentinel(context: RestoreContext) {
        do {
            try sentinelTerminator(context.plan.bundleIdentifier)
            log("Requested best-effort Sentinel termination.", context: context)
        } catch {
            log("Best-effort Sentinel termination failed: \(error.localizedDescription)", context: context)
        }
    }

    private func stageData(context: RestoreContext) throws {
        log("Preparing data staging directory at \(context.dataStagingURL.path).", context: context)
        try removeItemIfExists(context.dataStagingURL)
        try fileManager.createDirectory(at: context.dataStagingURL, withIntermediateDirectories: true)

        if context.plan.includeChromiumData {
            guard let snapshotApplicationSupportURL = context.plan.snapshotApplicationSupportURL else {
                throw TimeMachineInstallerCoreError.missingRequiredSnapshot(context.plan.currentApplicationSupportURL)
            }
            try requireExistingItem(snapshotApplicationSupportURL)
            log(
                "Staging full application support data from \(snapshotApplicationSupportURL.path) to " +
                "\(context.stagedApplicationSupportURL.path).",
                context: context
            )
            try fileCloner.copyItem(
                at: snapshotApplicationSupportURL,
                to: context.stagedApplicationSupportURL
            )
        } else {
            guard let snapshotPhiDataURL = context.plan.snapshotPhiDataURL else {
                throw TimeMachineInstallerCoreError.missingRequiredSnapshot(context.plan.currentPhiDataURL)
            }
            try requireExistingItem(snapshotPhiDataURL)
            log("Staging Phi data from \(snapshotPhiDataURL.path) to \(context.stagedPhiDataURL.path).", context: context)
            try fileCloner.copyItem(at: snapshotPhiDataURL, to: context.stagedPhiDataURL)
        }

        if let snapshotPreferencesURL = context.plan.snapshotPreferencesURL {
            try requireExistingItem(snapshotPreferencesURL)
            log("Staging preferences from \(snapshotPreferencesURL.path) to \(context.stagedPreferencesURL.path).", context: context)
            try fileCloner.copyItem(at: snapshotPreferencesURL, to: context.stagedPreferencesURL)
        } else {
            log("No preferences snapshot was included in the plan.", context: context)
        }
    }

    private func backupData(context: RestoreContext) throws {
        log("Creating emergency data backup under \(context.dataBackupURL.path).", context: context)
        try fileManager.createDirectory(at: context.dataBackupURL, withIntermediateDirectories: true)
        if context.plan.includeChromiumData {
            try backupItemIfNeeded(
                sourceURL: context.plan.currentApplicationSupportURL,
                backupURL: context.applicationSupportBackupURL,
                context: context
            )
        } else {
            try backupItemIfNeeded(
                sourceURL: context.plan.currentPhiDataURL,
                backupURL: context.phiBackupURL,
                context: context
            )
        }
        try backupItemIfNeeded(
            sourceURL: context.plan.currentPreferencesURL,
            backupURL: context.preferencesBackupURL,
            context: context
        )
    }

    private func swapData(context: RestoreContext) throws {
        log("Swapping live data paths.", context: context)
        if context.plan.includeChromiumData {
            try installStagedItem(
                context.stagedApplicationSupportURL,
                to: context.plan.currentApplicationSupportURL,
                context: context
            )
        } else {
            try installStagedItem(context.stagedPhiDataURL, to: context.plan.currentPhiDataURL, context: context)
        }

        if fileManager.fileExists(atPath: context.stagedPreferencesURL.path) {
            try installStagedItem(context.stagedPreferencesURL, to: context.plan.currentPreferencesURL, context: context)
        } else {
            try removeItemIfExists(context.plan.currentPreferencesURL)
        }
    }

    private func backupApp(context: RestoreContext) throws {
        try requireExistingItem(context.plan.currentAppURL)
        log("Creating emergency app backup under \(context.appBackupURL.path).", context: context)
        try fileManager.createDirectory(at: context.appBackupURL, withIntermediateDirectories: true)
        try backupItemIfNeeded(sourceURL: context.plan.currentAppURL, backupURL: context.currentAppBackupURL, context: context)
    }

    private func swapApp(context: RestoreContext) throws {
        try requireExistingItem(context.plan.stagedAppURL)
        log("Replacing app \(context.plan.currentAppURL.path) with staged app \(context.plan.stagedAppURL.path).", context: context)
        try installStagedItem(context.plan.stagedAppURL, to: context.plan.currentAppURL, context: context)
    }

    private func handleFailure(context: inout RestoreContext) throws {
        do {
            if context.journal.phase.requiresAppEmergencyRestore {
                log("Restoring app from emergency backup.", context: context)
                try restoreBackupItemIfNeeded(
                    backupURL: context.currentAppBackupURL,
                    targetURL: context.plan.currentAppURL,
                    stagingURL: context.appRestoreStagingURL,
                    context: context
                )
            }
            if context.journal.phase.requiresDataEmergencyRestore {
                log("Restoring data from emergency backup.", context: context)
                try revertData(context: context)
                try advancePhase(.reverted, context: &context)
            } else if context.journal.phase.needsRecovery {
                log("Marking restore operation as failed before live data was swapped.", context: context)
                try advancePhase(.failed, context: &context)
            }
        } catch {
            log("Failed to restore emergency backup: \(error.localizedDescription)", context: context)
            context.journal.phase = .failed
            context.journal.updatedAt = dateProvider()
            try? journalStore.write(context.journal)
            throw error
        }
    }

    private func revertData(context: RestoreContext) throws {
        if context.plan.includeChromiumData {
            try restoreBackupItemIfNeeded(
                backupURL: context.applicationSupportBackupURL,
                targetURL: context.plan.currentApplicationSupportURL,
                stagingURL: context.applicationSupportRestoreStagingURL,
                context: context
            )
        } else {
            try restoreBackupItemIfNeeded(
                backupURL: context.phiBackupURL,
                targetURL: context.plan.currentPhiDataURL,
                stagingURL: context.phiRestoreStagingURL,
                context: context
            )
        }

        try restoreBackupItemIfNeeded(
            backupURL: context.preferencesBackupURL,
            targetURL: context.plan.currentPreferencesURL,
            stagingURL: context.preferencesRestoreStagingURL,
            context: context
        )
    }

    private func backupItemIfNeeded(sourceURL: URL, backupURL: URL, context: RestoreContext) throws {
        guard fileManager.fileExists(atPath: sourceURL.path),
              !fileManager.fileExists(atPath: backupURL.path) else {
            if !fileManager.fileExists(atPath: sourceURL.path) {
                log("Skipping emergency backup because source is missing: \(sourceURL.path).", context: context)
            } else {
                log("Skipping emergency backup because backup already exists: \(backupURL.path).", context: context)
            }
            return
        }
        try fileManager.createDirectory(
            at: backupURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        log("Backing up \(sourceURL.path) to \(backupURL.path).", context: context)
        try fileCloner.copyItem(at: sourceURL, to: backupURL)
    }

    private func restoreBackupItemIfNeeded(
        backupURL: URL,
        targetURL: URL,
        stagingURL: URL,
        context: RestoreContext
    ) throws {
        if fileManager.fileExists(atPath: backupURL.path) {
            log("Restoring backup \(backupURL.path) to \(targetURL.path).", context: context)
            try removeItemIfExists(stagingURL)
            try fileCloner.copyItem(at: backupURL, to: stagingURL)
            try installStagedItem(stagingURL, to: targetURL, context: context)
        } else {
            log("Removing target because no emergency backup exists: \(targetURL.path).", context: context)
            try removeItemIfExists(targetURL)
        }
    }

    private func installStagedItem(_ stagedURL: URL, to targetURL: URL, context: RestoreContext) throws {
        try requireExistingItem(stagedURL)
        log("Installing staged item \(stagedURL.path) to \(targetURL.path).", context: context)
        try fileManager.createDirectory(
            at: targetURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        if fileManager.fileExists(atPath: targetURL.path) {
            _ = try fileManager.replaceItemAt(
                targetURL,
                withItemAt: stagedURL,
                backupItemName: nil,
                options: []
            )
        } else {
            try fileManager.moveItem(at: stagedURL, to: targetURL)
        }
    }

    private func advancePhase(_ phase: TimeMachineRestorePhase, context: inout RestoreContext) throws {
        context.journal.phase = phase
        context.journal.updatedAt = dateProvider()
        try journalStore.write(context.journal)
        log("Advanced restore phase to \(phase.rawValue).", context: context)
        try phaseObserver(phase)
    }

    private func requireExistingItem(_ url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else {
            throw TimeMachineInstallerCoreError.missingRequiredSnapshot(url)
        }
    }

    private func cleanupCompletedRestoreArtifacts(context: RestoreContext) {
        completedRestoreCleaner.cleanup(plan: context.plan, operationURL: context.operationURL) { message in
            log(message, context: context)
        }
    }

    private func removeItemIfExists(_ url: URL) throws {
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    private static func waitForHostExit(pid: Int32) throws {
        guard pid > 0 else {
            return
        }

        let deadline = Date().addingTimeInterval(120)
        while processExists(pid: pid) {
            guard Date() < deadline else {
                throw TimeMachineInstallerCoreError.hostProcessDidNotExit(pid)
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
    }

    private static func processExists(pid: Int32) -> Bool {
        guard pid > 0 else {
            return false
        }
        if kill(pid, 0) == 0 {
            return true
        }
        return errno == EPERM
    }

    private static func terminateSentinelBestEffort(browserBundleIdentifier: String) {
        let sentinelBundleIdentifier = expectedSentinelBundleIdentifier(forBrowserBundleIdentifier: browserBundleIdentifier)
        for app in NSWorkspace.shared.runningApplications {
            guard let bundleID = app.bundleIdentifier,
                  bundleID.caseInsensitiveCompare(sentinelBundleIdentifier) == .orderedSame,
                  !app.isTerminated else {
                continue
            }
            app.terminate()
        }
    }

    private static func expectedSentinelBundleIdentifier(forBrowserBundleIdentifier bundleIdentifier: String) -> String {
        let lowercased = bundleIdentifier.lowercased()
        if lowercased.contains(".canary.") || lowercased.contains("canary") {
            return "com.phibrowser.canary.Sentinel"
        }
        if lowercased.contains(".dev.") {
            return "com.phibrowser.dev.Sentinel"
        }
        return "com.phibrowser.Sentinel"
    }

    private static func openApp(_ appURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [appURL.path]
        try process.run()
    }

    private func scopeDescription(_ includeChromiumData: Bool) -> String {
        includeChromiumData ? "full" : "phi-only"
    }

    private func log(_ message: String, context: RestoreContext) {
        let line = "[TimeMachineInstaller] \(message)"
        logger(line)
        appendLogLine(line, to: context.operationURL.appendingPathComponent(Self.installerLogFilename))
    }

    private func appendLogLine(_ line: String, to logURL: URL) {
        let formatter = ISO8601DateFormatter()
        let data = Data("\(formatter.string(from: dateProvider())) \(line)\n".utf8)
        try? fileManager.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: logURL.path),
           let handle = try? FileHandle(forWritingTo: logURL) {
            defer {
                try? handle.close()
            }
            handle.seekToEndOfFile()
            handle.write(data)
        } else {
            try? data.write(to: logURL, options: .atomic)
        }
    }

    private static func logToStandardError(_ message: String) {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
    }

    private struct RestoreContext {
        let plan: TimeMachineInstallPlan
        var journal: TimeMachineRestoreJournal
        let operationURL: URL

        init(plan: TimeMachineInstallPlan, journal: TimeMachineRestoreJournal, paths: TimeMachinePaths) {
            self.plan = plan
            self.journal = journal
            self.operationURL = paths.pendingOperationURL(id: plan.operationID)
        }

        var dataStagingURL: URL {
            operationURL.appendingPathComponent(TimeMachineInstallerCore.dataStagingDirectoryName, isDirectory: true)
        }

        var stagedApplicationSupportURL: URL {
            dataStagingURL.appendingPathComponent(TimeMachineInstallerCore.applicationSupportStageName, isDirectory: true)
        }

        var stagedPhiDataURL: URL {
            dataStagingURL.appendingPathComponent(TimeMachineInstallerCore.phiStageName, isDirectory: true)
        }

        var stagedPreferencesURL: URL {
            dataStagingURL.appendingPathComponent(TimeMachineInstallerCore.preferencesStageName, isDirectory: false)
        }

        var appBackupURL: URL {
            plan.emergencyBackupURL.appendingPathComponent(TimeMachineInstallerCore.appBackupDirectoryName, isDirectory: true)
        }

        var dataBackupURL: URL {
            plan.emergencyBackupURL.appendingPathComponent(TimeMachineInstallerCore.dataBackupDirectoryName, isDirectory: true)
        }

        var currentAppBackupURL: URL {
            appBackupURL.appendingPathComponent(plan.currentAppURL.lastPathComponent, isDirectory: true)
        }

        var applicationSupportBackupURL: URL {
            dataBackupURL.appendingPathComponent(TimeMachineInstallerCore.applicationSupportStageName, isDirectory: true)
        }

        var phiBackupURL: URL {
            dataBackupURL.appendingPathComponent(TimeMachineInstallerCore.phiStageName, isDirectory: true)
        }

        var preferencesBackupURL: URL {
            dataBackupURL.appendingPathComponent(TimeMachineInstallerCore.preferencesStageName, isDirectory: false)
        }

        var restoreStagingURL: URL {
            operationURL.appendingPathComponent("RestoreStaging", isDirectory: true)
        }

        var appRestoreStagingURL: URL {
            restoreStagingURL.appendingPathComponent("App", isDirectory: true)
        }

        var applicationSupportRestoreStagingURL: URL {
            restoreStagingURL.appendingPathComponent(TimeMachineInstallerCore.applicationSupportStageName, isDirectory: true)
        }

        var phiRestoreStagingURL: URL {
            restoreStagingURL.appendingPathComponent(TimeMachineInstallerCore.phiStageName, isDirectory: true)
        }

        var preferencesRestoreStagingURL: URL {
            restoreStagingURL.appendingPathComponent(TimeMachineInstallerCore.preferencesStageName, isDirectory: false)
        }
    }
}

struct TimeMachineCompletedRestoreCleaner {
    private let paths: TimeMachinePaths
    private let catalogStore: TimeMachineCatalogStore
    private let fileManager: FileManager

    init(
        paths: TimeMachinePaths,
        catalogStore: TimeMachineCatalogStore? = nil,
        fileManager: FileManager = .default
    ) {
        self.paths = paths
        self.catalogStore = catalogStore ?? TimeMachineCatalogStore(paths: paths, fileManager: fileManager)
        self.fileManager = fileManager
    }

    func cleanup(plan: TimeMachineInstallPlan, operationURL: URL, logger: @escaping (String) -> Void) {
        cleanupConsumedBackup(plan: plan, logger: logger)
        removeEmptyCatalogIfNeeded(logger: logger)
        removeEmptyManagedDirectoryIfNeeded(paths.snapshotsRootURL, description: "snapshots", logger: nil)
        removeManagedItemIfExists(
            plan.emergencyBackupURL,
            under: paths.emergencyRootURL,
            description: "emergency backup",
            logger: logger
        )
        removeEmptyManagedDirectoryIfNeeded(paths.emergencyRootURL, description: "emergency", logger: logger)
        removeManagedItemIfExists(
            operationURL,
            under: paths.pendingRootURL,
            description: "pending operation",
            logger: logger
        )
        removeEmptyManagedDirectoryIfNeeded(paths.pendingRootURL, description: "pending", logger: nil)
        removeEmptyManagedDirectoryIfNeeded(paths.rootURL, description: "root", logger: nil)
    }

    private func cleanupConsumedBackup(plan: TimeMachineInstallPlan, logger: @escaping (String) -> Void) {
        var removedRecord: TimeMachineBackupRecord?
        if let backupID = plan.backupID {
            do {
                removedRecord = try catalogStore.removeBackup(id: backupID)
                if removedRecord != nil {
                    logger("Removed consumed backup catalog record \(backupID.uuidString).")
                } else {
                    logger("No consumed backup catalog record existed for \(backupID.uuidString).")
                }
            } catch {
                logger("Failed to remove consumed backup catalog record \(backupID.uuidString): \(error.localizedDescription)")
            }
        }

        if let snapshotURL = plan.snapshotURL ?? removedRecord.map({ paths.url(forRelativePath: $0.snapshotRelativePath) }) {
            removeConsumedSnapshotIfManaged(snapshotURL, logger: logger)
            removeEmptyManagedDirectoryIfNeeded(paths.snapshotsRootURL, description: "snapshots", logger: logger)

            if removedRecord == nil {
                removeCatalogRecordIfNeeded(snapshotURL: snapshotURL, logger: logger)
            }
        }
    }

    private func removeEmptyCatalogIfNeeded(logger: (String) -> Void) {
        do {
            guard try catalogStore.load().backups.isEmpty,
                  fileManager.fileExists(atPath: paths.catalogURL.path) else {
                return
            }
            try fileManager.removeItem(at: paths.catalogURL)
            logger("Removed empty Time Machine catalog at \(paths.catalogURL.path).")
        } catch {
            logger("Failed to remove empty Time Machine catalog at \(paths.catalogURL.path): \(error.localizedDescription)")
        }
    }

    private func removeCatalogRecordIfNeeded(snapshotURL: URL, logger: (String) -> Void) {
        guard isManagedChildURL(snapshotURL, under: paths.snapshotsRootURL) else {
            return
        }

        let relativePath = paths.relativePath(for: snapshotURL)
        guard relativePath != snapshotURL.standardizedFileURL.path else {
            return
        }

        do {
            if let record = try catalogStore.removeBackup(snapshotRelativePath: relativePath) {
                logger("Removed consumed backup catalog record \(record.id.uuidString) by snapshot path.")
            }
        } catch {
            logger("Failed to remove consumed backup catalog record for snapshot \(relativePath): \(error.localizedDescription)")
        }
    }

    private func removeConsumedSnapshotIfManaged(_ snapshotURL: URL, logger: (String) -> Void) {
        guard isManagedChildURL(snapshotURL, under: paths.snapshotsRootURL) else {
            logger("Skipping consumed snapshot cleanup outside managed snapshots root: \(snapshotURL.path).")
            return
        }

        do {
            try removeItemIfExists(snapshotURL)
            logger("Removed consumed backup snapshot at \(snapshotURL.path).")
        } catch {
            logger("Failed to remove consumed backup snapshot at \(snapshotURL.path): \(error.localizedDescription)")
        }
    }

    private func removeManagedItemIfExists(
        _ url: URL,
        under rootURL: URL,
        description: String,
        logger: (String) -> Void
    ) {
        guard isManagedChildURL(url, under: rootURL) else {
            logger("Skipping completed restore \(description) cleanup outside managed root: \(url.path).")
            return
        }
        guard fileManager.fileExists(atPath: url.path) else {
            return
        }

        do {
            logger("Removing completed restore \(description) at \(url.path).")
            try fileManager.removeItem(at: url)
        } catch {
            logger("Failed to remove completed restore \(description) at \(url.path): \(error.localizedDescription)")
        }
    }

    private func removeEmptyManagedDirectoryIfNeeded(_ url: URL, description: String, logger: ((String) -> Void)?) {
        guard isManagedURL(url, under: paths.rootURL), fileManager.fileExists(atPath: url.path) else {
            return
        }

        do {
            let visibleContents = try fileManager.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            guard visibleContents.isEmpty else {
                return
            }
            try fileManager.removeItem(at: url)
            logger?("Removed empty Time Machine \(description) directory at \(url.path).")
        } catch {
            logger?("Failed to remove empty Time Machine \(description) directory at \(url.path): \(error.localizedDescription)")
        }
    }

    private func isManagedURL(_ url: URL, under rootURL: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let rootPath = rootURL.standardizedFileURL.path
        return path == rootPath || path.hasPrefix("\(rootPath)/")
    }

    private func isManagedChildURL(_ url: URL, under rootURL: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let rootPath = rootURL.standardizedFileURL.path
        return path.hasPrefix("\(rootPath)/")
    }

    private func removeItemIfExists(_ url: URL) throws {
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }
}

private extension TimeMachineRestorePhase {
    var requiresDataEmergencyRestore: Bool {
        switch self {
        case .dataSwapStarted, .dataSwapped, .appBackedUp, .appSwapStarted, .appSwapped:
            return true
        case .prepared, .dataStaged, .dataBackedUp, .completed, .failed, .reverted:
            return false
        }
    }

    var requiresAppEmergencyRestore: Bool {
        switch self {
        case .appSwapStarted, .appSwapped:
            return true
        case .prepared, .dataStaged, .dataBackedUp, .dataSwapStarted, .dataSwapped, .appBackedUp, .completed, .failed, .reverted:
            return false
        }
    }
}

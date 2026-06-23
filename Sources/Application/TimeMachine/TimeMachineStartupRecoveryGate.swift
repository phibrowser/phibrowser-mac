// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

struct TimeMachineStartupRecoveryGate {
    typealias RecoveryLauncher = (URL, [String]) throws -> Void

    private let paths: TimeMachinePaths
    private let journalStore: TimeMachineRestoreJournalStore
    private let completedRestoreCleaner: TimeMachineCompletedRestoreCleaner
    private let isExecutableFile: (String) -> Bool
    private let recoveryLauncher: RecoveryLauncher
    private let dateProvider: () -> Date
    private let logger: (String) -> Void

    init(
        paths: TimeMachinePaths = TimeMachinePaths(),
        journalStore: TimeMachineRestoreJournalStore? = nil,
        catalogStore: TimeMachineCatalogStore? = nil,
        isExecutableFile: @escaping (String) -> Bool = FileManager.default.isExecutableFile(atPath:),
        recoveryLauncher: @escaping RecoveryLauncher = Self.launchRecoveryProcess,
        dateProvider: @escaping () -> Date = Date.init,
        logger: @escaping (String) -> Void = { AppLogInfo("[TimeMachine] \($0)") }
    ) {
        self.paths = paths
        self.journalStore = journalStore ?? TimeMachineRestoreJournalStore(paths: paths)
        self.completedRestoreCleaner = TimeMachineCompletedRestoreCleaner(
            paths: paths,
            catalogStore: catalogStore ?? TimeMachineCatalogStore(paths: paths, fileManager: .default)
        )
        self.isExecutableFile = isExecutableFile
        self.recoveryLauncher = recoveryLauncher
        self.dateProvider = dateProvider
        self.logger = logger
    }

    func recoverPendingRestoreIfNeeded() -> Bool {
        cleanupCompletedRestoreArtifacts()
        cleanupEmptyManagedDirectories()

        let pendingJournals: [TimeMachineRestoreJournal]
        do {
            pendingJournals = try journalStore.pendingJournalsNeedingRecovery()
        } catch {
            logger("Failed to inspect pending restore recovery state: \(error.localizedDescription)")
            return false
        }

        guard let journal = pendingJournals.first else {
            return false
        }

        let helperURL = paths.url(forRelativePath: journal.helperRelativePath)
        guard isExecutableFile(helperURL.path) else {
            return handleUnavailableHelper(journal: journal, helperURL: helperURL)
        }

        do {
            let arguments = Self.recoveryArguments(operationID: journal.operationID, rootURL: paths.rootURL)
            try recoveryLauncher(helperURL, arguments)
            logger("Launched restore recovery helper for operation \(journal.operationID.uuidString).")
            return true
        } catch {
            return handleRecoveryLaunchFailure(journal: journal, error: error)
        }
    }

    private func cleanupCompletedRestoreArtifacts() {
        let completedJournals: [TimeMachineRestoreJournal]
        do {
            completedJournals = try journalStore.completedPendingJournals()
        } catch {
            logger("Failed to inspect completed restore cleanup state: \(error.localizedDescription)")
            return
        }

        for journal in completedJournals {
            cleanupCompletedRestoreArtifacts(journal: journal)
        }
    }

    private func cleanupCompletedRestoreArtifacts(journal: TimeMachineRestoreJournal) {
        let planURL = paths.url(forRelativePath: journal.planRelativePath)
        do {
            let plan = try TimeMachineInstallerCore.loadPlan(at: planURL)
            completedRestoreCleaner.cleanup(
                plan: plan,
                operationURL: paths.pendingOperationURL(id: journal.operationID),
                logger: logger
            )
        } catch {
            logger("Failed to clean completed restore artifacts for \(journal.operationID.uuidString): \(error.localizedDescription)")
        }
    }

    private func cleanupEmptyManagedDirectories() {
        removeEmptyManagedDirectoryIfNeeded(paths.pendingRootURL, description: "pending")
        removeEmptyManagedDirectoryIfNeeded(paths.emergencyRootURL, description: "emergency")
        removeEmptyManagedDirectoryIfNeeded(paths.snapshotsRootURL, description: "snapshots")
    }

    private func handleUnavailableHelper(journal: TimeMachineRestoreJournal, helperURL: URL) -> Bool {
        if journal.phase.hasStartedDestructiveSwap {
            logger("Pending restore \(journal.operationID.uuidString) needs recovery, but helper is unavailable at \(helperURL.path). Blocking startup.")
            return true
        }

        markFailedBeforeDestructiveSwap(
            journal: journal,
            reason: "helper is unavailable at \(helperURL.path)"
        )
        return false
    }

    private func handleRecoveryLaunchFailure(journal: TimeMachineRestoreJournal, error: Error) -> Bool {
        if journal.phase.hasStartedDestructiveSwap {
            logger("Failed to launch restore recovery helper for operation \(journal.operationID.uuidString): \(error.localizedDescription). Blocking startup.")
            return true
        }

        markFailedBeforeDestructiveSwap(
            journal: journal,
            reason: "helper launch failed: \(error.localizedDescription)"
        )
        return false
    }

    private func markFailedBeforeDestructiveSwap(journal: TimeMachineRestoreJournal, reason: String) {
        var failedJournal = journal
        failedJournal.phase = .failed
        failedJournal.updatedAt = dateProvider()

        do {
            try journalStore.write(failedJournal)
            logger("Marked pending restore \(journal.operationID.uuidString) as failed before destructive swap because \(reason).")
        } catch {
            logger("Failed to mark pending restore \(journal.operationID.uuidString) as failed after \(reason): \(error.localizedDescription)")
        }
    }

    private func removeEmptyManagedDirectoryIfNeeded(_ url: URL, description: String) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return
        }

        do {
            let visibleContents = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            guard visibleContents.isEmpty else {
                return
            }

            try FileManager.default.removeItem(at: url)
            logger("Removed empty Time Machine \(description) directory at \(url.path).")
        } catch {
            logger("Failed to remove empty Time Machine \(description) directory at \(url.path): \(error.localizedDescription)")
        }
    }

    static func recoveryArguments(operationID: UUID, rootURL: URL) -> [String] {
        [
            "--time-machine-recover",
            "--operation-id",
            operationID.uuidString,
            "--time-machine-root",
            rootURL.path
        ]
    }

    private static func launchRecoveryProcess(executableURL: URL, arguments: [String]) throws {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        try process.run()
    }
}

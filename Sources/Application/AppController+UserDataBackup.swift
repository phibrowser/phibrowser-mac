// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import Darwin
import Foundation
import CoreData
import UniformTypeIdentifiers

struct PhiUserDataExportSelection: Equatable {
    var includeBrowserData: Bool
    var includeAIData: Bool

    var isExportable: Bool {
        includeBrowserData || includeAIData
    }
}

@MainActor
private final class PhiUserDataExportSelectionBox {
    var selection: PhiUserDataExportSelection
    var readState: (() -> PhiUserDataExportSelection)?

    init(browserDataAvailable: Bool) {
        selection = PhiUserDataExportSelection(
            includeBrowserData: browserDataAvailable,
            includeAIData: true
        )
    }
}

extension AppController {
    private enum PhiUserDataBackupPromptResult {
        case cancel
        case skipBackup
        case performBackup
    }

    private struct PhiUserDataImportStaging {
        let stagingURL: URL
        let extractedPhiURL: URL
        let referencedProfileIds: Set<String>
        let profileDisplayNames: [String: String]

        func cleanup() {
            try? FileManager.default.removeItem(at: stagingURL)
        }
    }

    private struct PhiUserDataProfileRepairResult {
        let profileIdRemaps: [String: String]
        let createdProfileIds: [String]
    }

    @MainActor
    @objc func clearAllUserData(_ sender: Any?) {
        beginClearUserDataFlow(includeAuthReset: true)
    }

    @MainActor
    @objc func exportUserData(_ sender: Any?) {
        _ = performPhiUserDataBackupExport()
    }

    @MainActor
    @objc func importUserDataFromBackup(_ sender: Any?) {
        let confirm = NSAlert()
        confirm.messageText = NSLocalizedString("app.userDataImport.confirmation.title", value: "Import Phi User Data?", comment: "User data import - Confirmation alert title before replacing Phi user data from zip")
        confirm.informativeText = NSLocalizedString("app.userDataImport.confirmation.message", value: "This replaces the Phi user data folder with the archive and restarts Phi. Save your work first.", comment: "User data import - Confirmation alert body warning data replacement and relaunch")
        confirm.alertStyle = .warning
        confirm.addButton(withTitle: NSLocalizedString("app.userDataImport.confirmation.importButton", value: "Import...", comment: "User data import - Alert button to open file picker for zip backup"))
        confirm.addButton(withTitle: NSLocalizedString("app.userDataImport.confirmation.cancelButton", value: "Cancel", comment: "User data import - Alert button to cancel importing user data"))
        guard confirm.runModal() == .alertFirstButtonReturn else {
            return
        }

        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.zip]
        panel.title = NSLocalizedString("app.userDataImport.filePicker.title", value: "Select Phi User Data Backup", comment: "User data import - NSOpenPanel title for choosing a Phi user data zip")

        guard panel.runModal() == .OK, let zipURL = panel.url else {
            return
        }

        do {
            let staging = try Self.preparePhiUserDataImport(from: zipURL)
            AppLogInfo("[Debug] Phi user data import prepared: archive=\(zipURL.path) referencedProfiles=\(Self.formatProfileIds(staging.referencedProfileIds))")
            // Defer Chromium-side extension preinstall for the profiles we
            // create here: this flow relaunches before an async install can
            // finish, so let the next launch run it. Read through the bridge by
            // both the default-apps (preinstalled) path and the iCloud
            // Passwords auto-install (PhiICloudPasswordsExternalLoader). Defer
            // clears it on every exit.
            PhiChromiumCoordinator.shared.isBackupImportInProgress = true
            Self.createMissingChromiumProfiles(
                for: staging.referencedProfileIds,
                displayNames: staging.profileDisplayNames
            ) { [weak self] result in
                guard let self else {
                    staging.cleanup()
                    return
                }
                switch result {
                case .success(let repairResult):
                    do {
                        AppLogInfo("[Debug] Phi user data import applying profile remaps: \(Self.formatProfileIdRemaps(repairResult.profileIdRemaps))")
                        try Self.applyImportedProfileIdRemaps(repairResult.profileIdRemaps, in: staging.extractedPhiURL)
                        AppLogInfo("[Debug] Phi user data import replacing Phi data directory")
                        try Self.replacePhiUserDataDirectory(withExtractedPhiAt: staging.extractedPhiURL)
                        staging.cleanup()
                        AppLogInfo("[Debug] Phi user data imported from \(zipURL.path), relaunching")
                        Self.relaunchPhiApplication()
                    } catch {
                        Self.rollbackCreatedChromiumProfiles(repairResult.createdProfileIds) {
                            staging.cleanup()
                            self.presentPhiUserDataImportFailure(error)
                        }
                    }
                case .failure(let error):
                    staging.cleanup()
                    presentPhiUserDataImportFailure(error)
                }
            }
        } catch {
            presentPhiUserDataImportFailure(error)
        }
    }

    @MainActor
    private func beginClearUserDataFlow(includeAuthReset: Bool) {
        guard showQuitAlert() else {
            return
        }

        switch promptBackupBeforeClearingPhiUserData() {
        case .cancel:
            return
        case .skipBackup:
            break
        case .performBackup:
            guard performPhiUserDataBackupExport() else {
                return
            }
        }

        if includeAuthReset {
            AuthManager.shared.clearLocalCredentials()
            LoginController.shared.phase = .login
        }
        // Last step before terminating: any defaults write after the
        // preferences domain is dropped would resurrect it in cfprefsd.
        UserDataRemoval.beginRemoval(of: .currentProduct)
        NSApp.terminate(nil)
    }

    @MainActor
    private func promptBackupBeforeClearingPhiUserData() -> PhiUserDataBackupPromptResult {
        let alert = NSAlert()
        alert.messageText = "Back Up User Data First?"
        alert.informativeText = "You can save a zip of your browser and AI data before local files are removed and the app quits."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Backup...")
        alert.addButton(withTitle: "Skip Backup")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return .performBackup
        case .alertSecondButtonReturn:
            return .skipBackup
        default:
            return .cancel
        }
    }

    @MainActor
    private func makeExportAccessoryView(
        box: PhiUserDataExportSelectionBox,
        browserDataAvailable: Bool
    ) -> NSView {
        let browserCheckbox = NSButton(
            checkboxWithTitle: NSLocalizedString(
                "app.userDataExport.category.browserDataLabel",
                value: "Browser data",
                comment: "User data export - Checkbox label for including browser data in the backup"
            ),
            target: nil,
            action: nil
        )
        browserCheckbox.state = box.selection.includeBrowserData ? .on : .off
        browserCheckbox.isEnabled = browserDataAvailable

        let aiCheckbox = NSButton(
            checkboxWithTitle: NSLocalizedString(
                "app.userDataExport.category.aiDataLabel",
                value: "AI data",
                comment: "User data export - Checkbox label for including AI data in the backup"
            ),
            target: nil,
            action: nil
        )
        aiCheckbox.state = box.selection.includeAIData ? .on : .off

        box.readState = {
            PhiUserDataExportSelection(
                includeBrowserData: browserCheckbox.state == .on,
                includeAIData: aiCheckbox.state == .on
            )
        }

        let stack = NSStackView(views: [browserCheckbox, aiCheckbox])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 64))
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8)
        ])
        return container
    }

    @MainActor
    private func performPhiUserDataBackupExport() -> Bool {
        let fm = FileManager.default
        let browserDataAvailable = Self.isDirectory(
            at: URL(
                fileURLWithPath: FileSystemUtils.phiBrowserDataDirectory(),
                isDirectory: true
            )
        )

        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = defaultPhiUserDataBackupFileName()
        panel.title = NSLocalizedString("app.userDataExport.savePanel.title", value: "Back Up Phi User Data", comment: "User data export - NSSavePanel title for saving Phi user data directory as zip")
        panel.prompt = NSLocalizedString("app.userDataExport.savePanel.saveButton", value: "Save", comment: "User data export - NSSavePanel confirm button title when saving Phi user data backup zip")

        let selectionBox = PhiUserDataExportSelectionBox(
            browserDataAvailable: browserDataAvailable
        )
        panel.accessoryView = makeExportAccessoryView(
            box: selectionBox,
            browserDataAvailable: browserDataAvailable
        )

        guard panel.runModal() == .OK, let destinationZIP = panel.url else {
            return false
        }

        let selection = selectionBox.readState?() ?? selectionBox.selection
        guard selection.isExportable else {
            let alert = NSAlert()
            alert.messageText = NSLocalizedString(
                "app.userDataExport.categorySelection.requiredMessage",
                value: "Select at least one category to back up.",
                comment: "User data export - Message when no backup category is selected"
            )
            alert.alertStyle = .informational
            alert.addButton(withTitle: NSLocalizedString(
                "app.userDataExport.categorySelection.dismissButton",
                value: "OK",
                comment: "User data export - Button dismissing the message that requires a backup category"
            ))
            alert.runModal()
            return false
        }

        let stagingDirectory = fm.temporaryDirectory.appendingPathComponent(
            "PhiDataExport-\(UUID().uuidString)",
            isDirectory: true
        )
        let stagedZIP = stagingDirectory.appendingPathComponent(
            "Phi-data.zip",
            isDirectory: false
        )

        do {
            try fm.createDirectory(
                at: stagingDirectory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            defer {
                try? fm.removeItem(at: stagingDirectory)
            }

            if selection.includeBrowserData {
                guard browserDataAvailable else {
                    throw NSError(
                        domain: "PhiUserDataBackup",
                        code: 2,
                        userInfo: [
                            NSLocalizedDescriptionKey: NSLocalizedString(
                                "app.userDataExport.browserDataUnavailable.message",
                                value: "The Phi browser data folder is no longer available.",
                                comment: "User data export - Error when browser data disappears before the backup starts"
                            )
                        ]
                    )
                }
                syncCurrentChromiumProfileDisplayNamesToLocalStore()
                try zipPhiBrowserDataDirectory(to: stagedZIP)
            }

            if selection.includeAIData {
                let aiResult = coordinateAIDataExport()
                switch aiResult.result {
                case .packed(let tarURL):
                    do {
                        try Self.appendAIDataArchive(tarURL, to: stagedZIP)
                        aiResult.session?.cleanup()
                    } catch {
                        aiResult.session?.cleanup()
                        AppLogWarn("[Manage User Data] Failed to add AI data to backup: \(error.localizedDescription)")
                        warnAIDataDegraded(
                            reason: .exportFailed,
                            browserDataIncluded: selection.includeBrowserData
                        )
                        guard selection.includeBrowserData else {
                            return false
                        }
                    }
                case .skipped(let reason):
                    if reason.shouldRetainSessionForLateWrite {
                        aiResult.session?.scheduleCleanup()
                    } else {
                        aiResult.session?.cleanup()
                    }
                    warnAIDataDegraded(
                        reason: reason,
                        browserDataIncluded: selection.includeBrowserData
                    )
                    guard selection.includeBrowserData else {
                        return false
                    }
                }
            }

            try Self.publishBackup(from: stagedZIP, to: destinationZIP)
            AppLogInfo("[Debug] Phi user data backup saved to \(destinationZIP.path)")
            return true
        } catch {
            AppLogWarn("[Debug] Phi user data backup failed: \(error.localizedDescription)")
            let errorAlert = NSAlert()
            errorAlert.messageText = NSLocalizedString("app.userDataExport.failure.title", value: "Backup Failed", comment: "User data export - Alert title when the requested backup cannot be created")
            errorAlert.informativeText = error.localizedDescription
            errorAlert.alertStyle = .warning
            errorAlert.addButton(withTitle: NSLocalizedString("app.userDataExport.failure.dismissButton", value: "OK", comment: "User data export - Failure alert dismiss button"))
            errorAlert.runModal()
            return false
        }
    }

    @MainActor
    private func coordinateAIDataExport() -> (
        result: AIDataExportCoordinator.Result,
        session: SentinelAIDataExportSession?
    ) {
        let service = SentinelAIDataExportService()
        let session: SentinelAIDataExportSession
        do {
            session = try service.prepareSession()
        } catch {
            AppLogWarn("[Manage User Data] Cannot prepare AI data export: \(error.localizedDescription)")
            return (.skipped(reason: .exportFailed), nil)
        }

        let cancellation = SentinelExportCancellation()
        let result = presentAIDataExportProgress(cancelBox: cancellation) {
            await service.coordinate(
                session: session,
                isCancelled: {
                    cancellation.isCancelled
                }
            )
        }
        return (result, session)
    }

    @MainActor
    private func presentAIDataExportProgress(
        cancelBox: SentinelExportCancellation,
        _ work: @escaping () async -> AIDataExportCoordinator.Result
    ) -> AIDataExportCoordinator.Result {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString(
            "app.userDataExport.aiDataProgress.title",
            value: "Backing Up AI Data",
            comment: "User data export - Progress alert title while AI data is being prepared"
        )
        alert.addButton(withTitle: NSLocalizedString(
            "app.userDataExport.aiDataProgress.cancelButton",
            value: "Cancel",
            comment: "User data export - Button cancelling AI data backup preparation"
        ))

        let progress = NSProgressIndicator(
            frame: NSRect(x: 0, y: 0, width: 300, height: 20)
        )
        progress.style = .bar
        progress.isIndeterminate = true
        progress.startAnimation(nil)
        alert.accessoryView = progress

        var workResult: AIDataExportCoordinator.Result?
        let task = Task { @MainActor in
            let result = await work()
            guard !Task.isCancelled else {
                return
            }
            workResult = result
            NSApp.stopModal()
        }

        let response = alert.runModal()
        if response == .stop, let workResult {
            return workResult
        }

        cancelBox.cancel()
        task.cancel()
        return .skipped(reason: .cancelled)
    }

    @MainActor
    private func warnAIDataDegraded(
        reason: AIDataExportCoordinator.SkipReason,
        browserDataIncluded: Bool
    ) {
        let detail: String
        switch (browserDataIncluded, reason) {
        case (true, .sentinelUnavailable):
            detail = NSLocalizedString(
                "app.userDataExport.aiData.partialFailure.serviceUnavailableMessage",
                value: "AI data was not included because Sentinel could not be started. Only browser data was backed up.",
                comment: "User data export - Warning when AI data cannot be prepared but browser data was backed up"
            )
        case (true, .timedOut):
            detail = NSLocalizedString(
                "app.userDataExport.aiData.partialFailure.timeoutMessage",
                value: "AI data was not included because Sentinel did not respond in time. Only browser data was backed up.",
                comment: "User data export - Warning when AI data preparation times out but browser data was backed up"
            )
        case (true, .exportFailed):
            detail = NSLocalizedString(
                "app.userDataExport.aiData.partialFailure.exportFailureMessage",
                value: "AI data was not included because Sentinel could not export it. Only browser data was backed up.",
                comment: "User data export - Warning when AI data preparation fails but browser data was backed up"
            )
        case (true, .invalidResponsePath):
            detail = NSLocalizedString(
                "app.userDataExport.aiData.partialFailure.invalidArchiveMessage",
                value: "AI data was not included because Sentinel returned an unexpected file. Only browser data was backed up.",
                comment: "User data export - Warning when the prepared AI data archive is invalid but browser data was backed up"
            )
        case (true, .cancelled):
            detail = NSLocalizedString(
                "app.userDataExport.aiData.partialFailure.cancelledMessage",
                value: "AI data backup was cancelled. Only browser data was backed up.",
                comment: "User data export - Warning when AI data backup is cancelled but browser data was backed up"
            )
        case (false, .sentinelUnavailable):
            detail = NSLocalizedString(
                "app.userDataExport.aiData.failure.serviceUnavailableMessage",
                value: "AI data could not be backed up because Sentinel could not be started. No backup was created.",
                comment: "User data export - Failure when AI data cannot be prepared and no browser data was selected"
            )
        case (false, .timedOut):
            detail = NSLocalizedString(
                "app.userDataExport.aiData.failure.timeoutMessage",
                value: "AI data could not be backed up because Sentinel did not respond in time. No backup was created.",
                comment: "User data export - Failure when AI data preparation times out and no browser data was selected"
            )
        case (false, .exportFailed):
            detail = NSLocalizedString(
                "app.userDataExport.aiData.failure.exportFailureMessage",
                value: "AI data could not be backed up because Sentinel could not export it. No backup was created.",
                comment: "User data export - Failure when AI data preparation fails and no browser data was selected"
            )
        case (false, .invalidResponsePath):
            detail = NSLocalizedString(
                "app.userDataExport.aiData.failure.invalidArchiveMessage",
                value: "AI data could not be backed up because Sentinel returned an unexpected file. No backup was created.",
                comment: "User data export - Failure when the prepared AI data archive is invalid and no browser data was selected"
            )
        case (false, .cancelled):
            detail = NSLocalizedString(
                "app.userDataExport.aiData.failure.cancelledMessage",
                value: "AI data backup was cancelled. No backup was created.",
                comment: "User data export - Failure when AI data backup is cancelled and no browser data was selected"
            )
        }

        let alert = NSAlert()
        alert.messageText = browserDataIncluded
            ? NSLocalizedString(
                "app.userDataExport.aiData.partialFailure.title",
                value: "AI Data Not Backed Up",
                comment: "User data export - Alert title when browser data succeeds but AI data is not backed up"
            )
            : NSLocalizedString(
                "app.userDataExport.failure.title",
                value: "Backup Failed",
                comment: "User data export - Alert title when the requested backup cannot be created"
            )
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.addButton(withTitle: NSLocalizedString(
            "app.userDataExport.aiData.result.dismissButton",
            value: "OK",
            comment: "User data export - Button dismissing an AI data backup result alert"
        ))
        alert.runModal()
    }

    private func defaultPhiUserDataBackupFileName() -> String {
        let rawBase: String
        if let account = AccountController.shared.account {
            if let name = account.userInfo?.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                rawBase = name
            } else if let email = account.userInfo?.email,
                      let localPart = email.split(separator: "@").first.map(String.init),
                      !localPart.isEmpty {
                rawBase = localPart
            } else {
                rawBase = account.userID
            }
        } else {
            rawBase = "Phi"
        }
        let sanitized = Self.sanitizedBackupFileNameComponent(rawBase)
        let fallbackSlug = "Phi"
        let resolvedSlug: String
        if sanitized.isEmpty {
            resolvedSlug = fallbackSlug
        } else {
            resolvedSlug = sanitized
        }
        let userSegment: String?
        if resolvedSlug.caseInsensitiveCompare("Phi") == .orderedSame {
            userSegment = nil
        } else {
            userSegment = resolvedSlug
        }

        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyyMMdd"
        let dateString = formatter.string(from: Date())
        if let userSegment {
            return "Phi-\(userSegment)-data-\(dateString).zip"
        }
        return "Phi-data-\(dateString).zip"
    }

    @MainActor
    private func syncCurrentChromiumProfileDisplayNamesToLocalStore() {
        ProfileManager.shared.refresh()
        var displayNames: [String: String] = [:]
        for profile in ProfileManager.shared.profiles {
            displayNames[profile.profileId] = profile.displayName
        }
        AccountController.shared.account?.localStorage.upsertProfileDisplayNames(displayNames)
    }

    private static func sanitizedBackupFileNameComponent(_ raw: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let replaced = trimmed.components(separatedBy: invalid).joined(separator: "-")
        return replaced.trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    private func zipPhiBrowserDataDirectory(to destinationZIP: URL) throws {
        let fm = FileManager.default
        let parentURL = URL(fileURLWithPath: FileSystemUtils.applicationSupportDirctory(), isDirectory: true)
        let phiFolderName = (FileSystemUtils.phiBrowserDataDirectory() as NSString).lastPathComponent

        if fm.fileExists(atPath: destinationZIP.path) {
            try fm.removeItem(at: destinationZIP)
        }

        try Self.runZip(
            arguments: ["-r", "-q", destinationZIP.path, phiFolderName],
            currentDirectoryURL: parentURL
        )
    }

    static func appendAIDataArchive(_ tarURL: URL, to destinationZIP: URL) throws {
        let fm = FileManager.default
        let entryName = SentinelAIDataExportSession.archiveFileName
        let stagingParent = fm.temporaryDirectory.appendingPathComponent(
            "PhiAIDataZip-\(UUID().uuidString)",
            isDirectory: true
        )
        try fm.createDirectory(
            at: stagingParent,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer {
            try? fm.removeItem(at: stagingParent)
        }

        try copyOpenedRegularFile(
            from: tarURL,
            to: stagingParent.appendingPathComponent(entryName)
        )
        try runZip(
            arguments: ["-q", destinationZIP.path, entryName],
            currentDirectoryURL: stagingParent
        )
    }

    private static func copyOpenedRegularFile(
        from sourceURL: URL,
        to destinationURL: URL
    ) throws {
        let sourceDescriptor = sourceURL.withUnsafeFileSystemRepresentation {
            guard let fileSystemPath = $0 else {
                return Int32(-1)
            }
            return Darwin.open(
                fileSystemPath,
                O_RDONLY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard sourceDescriptor >= 0 else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [
                    NSLocalizedDescriptionKey: NSLocalizedString(
                        "app.userDataExport.aiData.archive.openFailureMessage",
                        value: "Could not safely open the AI data archive.",
                        comment: "User data export - Error when the prepared AI data archive cannot be opened safely"
                    )
                ]
            )
        }

        let sourceHandle = FileHandle(
            fileDescriptor: sourceDescriptor,
            closeOnDealloc: true
        )
        defer {
            try? sourceHandle.close()
        }

        var fileStatus = stat()
        guard Darwin.fstat(sourceDescriptor, &fileStatus) == 0 else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [
                    NSLocalizedDescriptionKey: NSLocalizedString(
                        "app.userDataExport.aiData.archive.inspectionFailureMessage",
                        value: "Could not inspect the AI data archive.",
                        comment: "User data export - Error when the prepared AI data archive cannot be inspected"
                    )
                ]
            )
        }
        guard fileStatus.st_mode & S_IFMT == S_IFREG else {
            throw NSError(
                domain: "PhiUserDataBackup",
                code: 5,
                userInfo: [
                    NSLocalizedDescriptionKey: NSLocalizedString(
                        "app.userDataExport.aiData.archive.invalidFileMessage",
                        value: "The AI data archive is not a regular file.",
                        comment: "User data export - Error when the prepared AI data archive is not a regular file"
                    )
                ]
            )
        }

        guard FileManager.default.createFile(
            atPath: destinationURL.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw NSError(
                domain: "PhiUserDataBackup",
                code: 6,
                userInfo: [
                    NSLocalizedDescriptionKey: NSLocalizedString(
                        "app.userDataExport.aiData.archive.stagingFailureMessage",
                        value: "Could not stage the AI data archive.",
                        comment: "User data export - Error when the prepared AI data archive cannot be staged for backup"
                    )
                ]
            )
        }

        let destinationHandle = try FileHandle(forWritingTo: destinationURL)
        defer {
            try? destinationHandle.close()
        }
        while let chunk = try sourceHandle.read(upToCount: 1024 * 1024),
              !chunk.isEmpty {
            try destinationHandle.write(contentsOf: chunk)
        }
        try destinationHandle.synchronize()
    }

    private static func runZip(
        arguments: [String],
        currentDirectoryURL: URL
    ) throws {
        let stderrPipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectoryURL
        process.standardError = stderrPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let errText = String(
                data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let detail = errText.isEmpty
                ? "zip exited with status \(process.terminationStatus)."
                : errText
            throw NSError(
                domain: "PhiUserDataBackup",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: detail]
            )
        }
    }

    private static func publishBackup(
        from stagedZIP: URL,
        to destinationZIP: URL
    ) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: stagedZIP.path) else {
            throw NSError(
                domain: "PhiUserDataBackup",
                code: 3,
                userInfo: [
                    NSLocalizedDescriptionKey: NSLocalizedString(
                        "app.userDataExport.archive.missingOutputMessage",
                        value: "No backup archive was produced.",
                        comment: "User data export - Error when the requested backup produces no archive"
                    )
                ]
            )
        }

        let temporaryDestination = destinationZIP
            .deletingLastPathComponent()
            .appendingPathComponent(
                ".\(destinationZIP.lastPathComponent).\(UUID().uuidString).tmp"
            )
        defer {
            try? fm.removeItem(at: temporaryDestination)
        }

        try fm.copyItem(at: stagedZIP, to: temporaryDestination)
        if fm.fileExists(atPath: destinationZIP.path) {
            _ = try fm.replaceItemAt(
                destinationZIP,
                withItemAt: temporaryDestination
            )
        } else {
            try fm.moveItem(at: temporaryDestination, to: destinationZIP)
        }
    }

    @MainActor
    private func presentPhiUserDataImportFailure(_ error: Error) {
        AppLogWarn("[Debug] Phi user data import failed: \(error.localizedDescription)")
        let errorAlert = NSAlert()
        errorAlert.messageText = NSLocalizedString("app.userDataImport.failure.title", value: "Import Failed", comment: "User data import - Alert title when extracting or applying backup fails")
        errorAlert.informativeText = error.localizedDescription
        errorAlert.alertStyle = .warning
        errorAlert.addButton(withTitle: NSLocalizedString("app.userDataImport.failure.dismissButton", value: "OK", comment: "User data import - Failure alert dismiss button"))
        errorAlert.runModal()
    }

    private static func preparePhiUserDataImport(from zipURL: URL) throws -> PhiUserDataImportStaging {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("PhiDataImport-\(UUID().uuidString)", isDirectory: true)
        var shouldCleanupStaging = true
        defer {
            if shouldCleanupStaging {
                try? fm.removeItem(at: staging)
            }
        }
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)

        try runUnzip(archive: zipURL, destination: staging)
        AppLogInfo("[Debug] Phi user data import archive extracted to \(staging.path)")

        let extractedPhi = staging.appendingPathComponent("Phi", isDirectory: true)
        guard isDirectory(at: extractedPhi) else {
            throw NSError(
                domain: "PhiUserDataImport",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("app.userDataImport.invalidArchive.missingTopLevelFolder", value: "The archive does not contain a top-level Phi folder.", comment: "User data import - Error message when zip does not include the expected Phi directory at archive root")]
            )
        }

        do {
            let referencedProfileIds = try importedProfileIds(in: extractedPhi)
            let profileDisplayNames = try importedProfileDisplayNames(in: extractedPhi)
            AppLogInfo("[Debug] Phi user data import found referenced profiles: \(formatProfileIds(referencedProfileIds))")
            shouldCleanupStaging = false
            return PhiUserDataImportStaging(
                stagingURL: staging,
                extractedPhiURL: extractedPhi,
                referencedProfileIds: referencedProfileIds,
                profileDisplayNames: profileDisplayNames
            )
        }
    }

    private static func replacePhiUserDataDirectory(withExtractedPhiAt extractedPhi: URL) throws {
        let fm = FileManager.default
        let parentURL = URL(fileURLWithPath: FileSystemUtils.applicationSupportDirctory(), isDirectory: true)
        let phiURL = URL(fileURLWithPath: FileSystemUtils.phiBrowserDataDirectory(), isDirectory: true)

        guard isDirectory(at: extractedPhi) else {
            throw NSError(
                domain: "PhiUserDataImport",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("app.userDataImport.invalidArchive.restoredItemNotDirectory", value: "The restored Phi user data is not a directory.", comment: "User data import - Error message when extracted Phi item is not a directory")]
            )
        }

        try fm.createDirectory(at: parentURL, withIntermediateDirectories: true)
        let preparedPhiURL = parentURL.appendingPathComponent(".PhiImportPrepared-\(UUID().uuidString)", isDirectory: true)
        let previousPhiURL = parentURL.appendingPathComponent(".PhiImportPrevious-\(UUID().uuidString)", isDirectory: true)
        var movedExistingPhi = false

        do {
            try fm.copyItem(at: extractedPhi, to: preparedPhiURL)
            if fm.fileExists(atPath: phiURL.path) {
                try fm.moveItem(at: phiURL, to: previousPhiURL)
                movedExistingPhi = true
            }
            try fm.moveItem(at: preparedPhiURL, to: phiURL)
            if movedExistingPhi {
                do {
                    try fm.removeItem(at: previousPhiURL)
                } catch {
                    AppLogWarn("[Debug] Phi user data import left previous Phi data directory at \(previousPhiURL.path): \(error.localizedDescription)")
                }
            }
        } catch {
            try? fm.removeItem(at: preparedPhiURL)
            if movedExistingPhi, !fm.fileExists(atPath: phiURL.path), fm.fileExists(atPath: previousPhiURL.path) {
                do {
                    try fm.moveItem(at: previousPhiURL, to: phiURL)
                    AppLogInfo("[Debug] Phi user data import restored previous Phi data directory after replace failure")
                } catch {
                    AppLogWarn("[Debug] Phi user data import failed to restore previous Phi data directory: \(error.localizedDescription)")
                }
            }
            throw error
        }
    }

    private static func isDirectory(at url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private static func importedProfileIds(in phiDataURL: URL) throws -> Set<String> {
        var profileIds = Set<String>()
        for storeDirectoryURL in try importedLocalStoreDirectoryURLs(in: phiDataURL) {
            profileIds.formUnion(try profileIdsReferencedBySpaces(inStoreDirectory: storeDirectoryURL))
        }
        return profileIds
    }

    private static func importedProfileDisplayNames(in phiDataURL: URL) throws -> [String: String] {
        var displayNames: [String: String] = [:]
        for storeDirectoryURL in try importedLocalStoreDirectoryURLs(in: phiDataURL) {
            // A Chromium profileId should represent the same global profile
            // across imported user stores. If snapshots disagree, keep the
            // first value; the mismatch belongs to profile snapshot drift,
            // not restore-time arbitration.
            displayNames.merge(
                try profileDisplayNames(inStoreDirectory: storeDirectoryURL),
                uniquingKeysWith: { existing, _ in existing }
            )
        }
        return displayNames
    }

    private static func importedLocalStoreDirectoryURLs(in phiDataURL: URL) throws -> [URL] {
        let fm = FileManager.default
        let usersURL = phiDataURL.appendingPathComponent("users", isDirectory: true)
        guard fm.fileExists(atPath: usersURL.path) else {
            return []
        }

        return try fm.contentsOfDirectory(
            at: usersURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ).compactMap { userURL in
            let values = try? userURL.resourceValues(forKeys: [.isDirectoryKey])
            guard values?.isDirectory == true else {
                return nil
            }
            let storeDirectoryURL = userURL.appendingPathComponent("localDB", isDirectory: true)
            let storeURL = storeDirectoryURL.appendingPathComponent(LocalStore.compatibilityConfiguration.storeFilename)
            guard fm.fileExists(atPath: storeURL.path) else {
                return nil
            }
            return storeDirectoryURL
        }
    }

    private static func profileIdsReferencedBySpaces(inStoreDirectory storeDirectoryURL: URL) throws -> Set<String> {
        let container = try openImportedLocalStoreContainer(at: storeDirectoryURL)
        let context = container.viewContext
        let spaces = try context.performAndWait {
            try context.fetch(SpaceModel.request())
        }
        return Set(spaces.map(\.profileId))
    }

    private static func profileDisplayNames(inStoreDirectory storeDirectoryURL: URL) throws -> [String: String] {
        let container = try openImportedLocalStoreContainer(at: storeDirectoryURL)
        let context = container.viewContext
        let profiles = try context.performAndWait {
            try context.fetch(ProfileModel.request())
        }
        var displayNames: [String: String] = [:]
        for profile in profiles {
            guard let displayName = profile.displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !displayName.isEmpty else {
                continue
            }
            displayNames[profile.profileId] = displayName
        }
        return displayNames
    }

    private static func openImportedLocalStoreContainer(at storeDirectoryURL: URL) throws -> NSPersistentContainer {
        let compatibilityController = LocalStoreCompatibilityController(
            configuration: LocalStore.compatibilityConfiguration
        )
        let compatibilityResult = try compatibilityController.prepareStore(at: storeDirectoryURL)
        let openPlan: LocalStoreOpenPlan
        switch compatibilityResult {
        case .ready(let plan):
            openPlan = plan
        case .requiresNewerApp(let issue):
            throw NSError(
                domain: "PhiUserDataImport",
                code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey: "The imported local store at \(storeDirectoryURL.path) requires a newer Phi data format (\(issue.activeStoreFormatVersion))."
                ]
            )
        }

        let storeFileURL = storeDirectoryURL.appendingPathComponent(LocalStore.compatibilityConfiguration.storeFilename)
        // Backups written by SwiftData builds (format <= 9) are converted in
        // place before opening, exactly like the main store.
        if openPlan.activeStoreFormatVersion < 10,
           FileManager.default.fileExists(atPath: storeFileURL.path) {
            try LocalStoreLegacyImport.convertStore(
                at: storeDirectoryURL,
                storeFilename: LocalStore.compatibilityConfiguration.storeFilename
        )
        }

        let container = try LocalStore.makeContainer(storeFileURL: storeFileURL)
        try compatibilityController.markStoreOpenedSuccessfully(openPlan, at: storeDirectoryURL)
        return container
    }

    @MainActor
    private static func createMissingChromiumProfiles(
        for importedProfileIds: Set<String>,
        displayNames importedDisplayNames: [String: String],
        completion: @escaping (Result<PhiUserDataProfileRepairResult, Error>) -> Void
    ) {
        let profileManager = ProfileManager.shared
        profileManager.refresh()
        let existingProfileIds = Set(profileManager.profiles.map(\.profileId))
        var pendingProfileIds = Set(importedProfileIds.filter { $0 != LocalStore.defaultProfileId && !existingProfileIds.contains($0) })

        guard !pendingProfileIds.isEmpty else {
            AppLogInfo("[Debug] Phi user data import profile repair: no missing Chromium profiles")
            completion(.success(PhiUserDataProfileRepairResult(profileIdRemaps: [:], createdProfileIds: [])))
            return
        }

        AppLogInfo("[Debug] Phi user data import profile repair: missingChromiumProfiles=\(formatProfileIds(pendingProfileIds))")
        var profileIdRemaps: [String: String] = [:]
        var createdProfileIds: [String] = []

        func failAndRollback(_ error: Error) {
            rollbackCreatedChromiumProfiles(createdProfileIds) {
                completion(.failure(error))
            }
        }

        func createNextProfile() {
            profileManager.refresh()
            let existingProfileIds = Set(profileManager.profiles.map(\.profileId))
            let satisfiedProfileIds = pendingProfileIds.intersection(existingProfileIds)
            if !satisfiedProfileIds.isEmpty {
                for profileId in satisfiedProfileIds {
                    AppLogInfo("[Debug] Phi user data import profile repair satisfied imported profile \(profileId)")
                    pendingProfileIds.remove(profileId)
                }
            }

            guard let importedProfileId = pendingProfileIds.sorted(by: importedProfileRestoreSort).first else {
                AppLogInfo("[Debug] Phi user data import profile repair completed: remaps=\(formatProfileIdRemaps(profileIdRemaps))")
                completion(.success(PhiUserDataProfileRepairResult(profileIdRemaps: profileIdRemaps, createdProfileIds: createdProfileIds)))
                return
            }

            let displayName = restoredProfileDisplayName(
                for: importedProfileId,
                importedDisplayName: importedDisplayNames[importedProfileId]
            )
            AppLogInfo("[Debug] Phi user data import profile repair creating Chromium profile for \(importedProfileId)")
            profileManager.createProfile(displayName: displayName) { newProfileId in
                guard let newProfileId else {
                    failAndRollback(profileRepairError("Failed to create Chromium profile for imported profile \(importedProfileId)."))
                    return
                }
                createdProfileIds.append(newProfileId)

                if newProfileId == importedProfileId {
                    pendingProfileIds.remove(importedProfileId)
                    AppLogInfo("[Debug] Phi user data import profile repair created Chromium profile \(newProfileId)")
                } else if pendingProfileIds.contains(newProfileId) {
                    pendingProfileIds.remove(newProfileId)
                    AppLogInfo("[Debug] Phi user data import profile repair created Chromium profile \(newProfileId), satisfying imported profile \(newProfileId) before remapping \(importedProfileId)")
                } else {
                    profileIdRemaps[importedProfileId] = newProfileId
                    pendingProfileIds.remove(importedProfileId)
                    AppLogInfo("[Debug] Phi user data import profile repair created Chromium profile \(newProfileId) for imported profile \(importedProfileId)")
                }
                createNextProfile()
            }
        }

        createNextProfile()
    }

    @MainActor
    private static func restoredProfileDisplayName(for importedProfileId: String, importedDisplayName: String?) -> String {
        let profileManager = ProfileManager.shared
        profileManager.refresh()
        let preferredName = importedDisplayName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let baseName: String
        if let preferredName, !preferredName.isEmpty {
            baseName = preferredName
        } else {
            baseName = importedProfileId
        }

        if !profileManager.displayNameExists(baseName) {
            return baseName
        }

        let restoredName = "Restored \(baseName)"
        if !profileManager.displayNameExists(restoredName) {
            return restoredName
        }

        var suffix = 2
        while profileManager.displayNameExists("\(restoredName) \(suffix)") {
            suffix += 1
        }
        return "\(restoredName) \(suffix)"
    }

    @MainActor
    private static func rollbackCreatedChromiumProfiles(_ profileIds: [String], completion: @escaping () -> Void) {
        let rollbackProfileIds = profileIds.reversed()
        guard !rollbackProfileIds.isEmpty else {
            completion()
            return
        }

        AppLogInfo("[Debug] Phi user data import profile repair rolling back Chromium profiles: \(formatProfileIds(Set(profileIds)))")

        func deleteNext(index: ReversedCollection<[String]>.Index) {
            guard index != rollbackProfileIds.endIndex else {
                completion()
                return
            }

            let profileId = rollbackProfileIds[index]
            ProfileManager.shared.deleteProfile(profileId) { success, error in
                if success {
                    AppLogInfo("[Debug] Phi user data import profile repair rolled back Chromium profile \(profileId)")
                } else {
                    AppLogWarn("[Debug] Phi user data import profile repair failed to roll back Chromium profile \(profileId): \(error ?? "unknown error")")
                }
                deleteNext(index: rollbackProfileIds.index(after: index))
            }
        }

        deleteNext(index: rollbackProfileIds.startIndex)
    }

    private static func formatProfileIds(_ profileIds: Set<String>) -> String {
        let sorted = profileIds.sorted(by: importedProfileRestoreSort)
        return sorted.isEmpty ? "none" : sorted.joined(separator: ",")
    }

    private static func formatProfileIdRemaps(_ profileIdRemaps: [String: String]) -> String {
        guard !profileIdRemaps.isEmpty else {
            return "none"
        }
        return profileIdRemaps
            .sorted { lhs, rhs in importedProfileRestoreSort(lhs.key, rhs.key) }
            .map { "\($0.key)->\($0.value)" }
            .joined(separator: ",")
    }

    private static func importedProfileRestoreSort(_ lhs: String, _ rhs: String) -> Bool {
        let lhsProfileNumber = chromiumGeneratedProfileNumber(lhs)
        let rhsProfileNumber = chromiumGeneratedProfileNumber(rhs)
        switch (lhsProfileNumber, rhsProfileNumber) {
        case let (lhs?, rhs?):
            return lhs < rhs
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        case (nil, nil):
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
    }

    private static func chromiumGeneratedProfileNumber(_ profileId: String) -> Int? {
        let prefix = "Profile "
        guard profileId.hasPrefix(prefix) else {
            return nil
        }
        return Int(profileId.dropFirst(prefix.count))
    }

    private static func applyImportedProfileIdRemaps(_ profileIdRemaps: [String: String], in phiDataURL: URL) throws {
        let effectiveRemaps = profileIdRemaps.filter { $0.key != $0.value }
        guard !effectiveRemaps.isEmpty else {
            return
        }

        for storeDirectoryURL in try importedLocalStoreDirectoryURLs(in: phiDataURL) {
            try applyImportedProfileIdRemaps(effectiveRemaps, inStoreDirectory: storeDirectoryURL)
        }
    }

    private static func applyImportedProfileIdRemaps(_ profileIdRemaps: [String: String], inStoreDirectory storeDirectoryURL: URL) throws {
        let container = try openImportedLocalStoreContainer(at: storeDirectoryURL)
        let context = container.viewContext
        try context.performAndWait {
            try applyImportedProfileIdRemaps(profileIdRemaps, in: context)
        }
    }

    private static func applyImportedProfileIdRemaps(_ profileIdRemaps: [String: String], in context: NSManagedObjectContext) throws {
        var didChange = false

        let spaces = try context.fetch(SpaceModel.request())
        for space in spaces {
            guard let newProfileId = profileIdRemaps[space.profileId] else {
                continue
            }
            space.profileId = newProfileId
            space.updatedDate = Date()
            didChange = true
        }

        let tabs = try context.fetch(TabDataModel.request())
        for tab in tabs {
            guard let oldProfileId = tab.profileId,
                  let newProfileId = profileIdRemaps[oldProfileId] else {
                continue
            }
            tab.profileId = newProfileId
            tab.updatedDate = Date()
            didChange = true
        }

        let profiles = try context.fetch(ProfileModel.request())
        var profilesById: [String: ProfileModel] = Dictionary(
            uniqueKeysWithValues: profiles.map { ($0.profileId, $0) }
        )
        for profile in profiles {
            guard let newProfileId = profileIdRemaps[profile.profileId] else {
                continue
            }
            if let targetProfile = profilesById[newProfileId], targetProfile !== profile {
                for tab in profile.tabs {
                    tab.profile = targetProfile
                    tab.profileId = newProfileId
                }
                if targetProfile.bookmarkRoot == nil {
                    targetProfile.bookmarkRoot = profile.bookmarkRoot
                }
                if targetProfile.displayName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
                    targetProfile.displayName = profile.displayName
                }
                context.delete(profile)
            } else {
                profilesById.removeValue(forKey: profile.profileId)
                profile.profileId = newProfileId
                profilesById[newProfileId] = profile
            }
            didChange = true
        }

        if didChange {
            try context.save()
        }
    }

    private static func profileRepairError(_ message: String) -> NSError {
        NSError(
            domain: "PhiUserDataImport",
            code: 3,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    private static func runUnzip(archive: URL, destination: URL) throws {
        let stderrPipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-q", archive.path, "-d", destination.path]
        process.standardError = stderrPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let errText = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let detail = errText.isEmpty ? "unzip exited with status \(process.terminationStatus)." : errText
            throw NSError(domain: "PhiUserDataImport", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: detail])
        }
    }

    private static func relaunchPhiApplication() {
        let bundlePath = Bundle.main.bundleURL.path
        let quoted = shellSingleQuotedForSh(bundlePath)
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", "( sleep 0.5; /usr/bin/open -n \(quoted) ) &"]
        do {
            try relaunch.run()
            relaunch.waitUntilExit()
        } catch {
            AppLogWarn("[Debug] Failed to schedule relaunch after quit: \(error.localizedDescription)")
        }
        DispatchQueue.main.async {
            NSApp.terminate(nil)
        }
    }

    private static func shellSingleQuotedForSh(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

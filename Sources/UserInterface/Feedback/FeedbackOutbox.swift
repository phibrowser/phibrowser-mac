// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import Carbon.HIToolbox
import Foundation
import UniformTypeIdentifiers

@MainActor
final class FeedbackViewModel: ObservableObject {
    @Published var urlString: String = ""
    @Published var descriptionText: String = ""
    @Published private(set) var attachments: [FeedbackDraftAttachment] = []
    @Published var localSaveError: String?
    @Published var attachmentError: String?
    @Published var isSubmitting: Bool = false
    @Published private(set) var previousSessionCrash: PreviousSessionCrashContext?

    var pageTitle: String?
    var componentVersions: [String: String] = [:]

    var canSend: Bool {
        !isSubmitting && !descriptionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasUserDraft: Bool {
        !descriptionText.isEmpty || !attachments.isEmpty
    }

    @discardableResult
    func setPreviousSessionCrash(_ context: PreviousSessionCrashContext) -> Bool {
        guard !isSubmitting, !hasUserDraft else { return false }
        previousSessionCrash = context
        urlString = ""
        pageTitle = nil
        return true
    }

    func clearPreviousSessionCrash() {
        guard previousSessionCrash != nil else { return }
        previousSessionCrash = nil
        descriptionText = ""
        urlString = ""
        pageTitle = nil
        attachments = []
        localSaveError = nil
        attachmentError = nil
    }

    func addFileURLs(_ urls: [URL]) {
        guard !isSubmitting else { return }
        var errors: [String] = []

        for url in urls {
            let didAccess = url.startAccessingSecurityScopedResource()
            defer {
                if didAccess {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            do {
                let info = try FeedbackOutbox.selectedAttachmentInfo(for: url)
                attachments.append(FeedbackDraftAttachment(
                    filename: url.lastPathComponent,
                    size: info.size,
                    kind: info.isImage ? .image : .file,
                    source: .file(url)
                ))
            } catch {
                errors.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }

        if !errors.isEmpty {
            let shownErrors = errors.prefix(3).joined(separator: "\n")
            let remaining = errors.count - 3
            attachmentError = remaining > 0 ? "\(shownErrors)\n+\(remaining) more" : shownErrors
        }
    }

    func addPastedImage(_ image: NSImage) {
        guard !isSubmitting else { return }
        guard let data = FeedbackImageEncoder.pngData(from: image) else {
            AppLogError("Feedback paste image failed: could not encode image data")
            return
        }
        let index = attachments.filter { $0.kind == .image }.count + 1
        attachments.append(FeedbackDraftAttachment(
            filename: "image-\(index).png",
            size: Int64(data.count),
            kind: .image,
            source: .pastedImage(data)
        ))
    }

    func removeAttachment(id: UUID) {
        guard !isSubmitting else { return }
        attachments.removeAll { $0.id == id }
    }

    func enqueueFeedback(
        chromiumSystemLogsText: String? = nil,
        inputSourceMetadata: [String: String]
    ) async throws {
        guard ApplicationState.shared.isAuthenticated,
              let account = AccountController.shared.account else {
            throw FeedbackOutboxError.missingAccount
        }

        let trimmedDescription = descriptionText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDescription.isEmpty else {
            throw FeedbackOutboxError.emptyDescription
        }

        let draft = FeedbackDraft(
            description: trimmedDescription,
            pageURL: urlString.trimmingCharacters(in: .whitespacesAndNewlines),
            pageTitle: pageTitle,
            contactEmail: account.userInfo?.email,
            components: FeedbackOutbox.feedbackComponents(extensionVersions: componentVersions),
            chromiumSystemLogsText: chromiumSystemLogsText,
            attachments: attachments,
            previousSessionCrash: previousSessionCrash,
            inputSourceMetadata: inputSourceMetadata
        )

        try await FeedbackOutbox.enqueue(draft, account: account)
        FeedbackOutboxUploader.shared.scheduleCurrentAccountProcessing()
    }
}

struct FeedbackDraftAttachment: Identifiable {
    enum Kind {
        case image
        case file
    }

    enum Source {
        case file(URL)
        case pastedImage(Data)
    }

    let id = UUID()
    let filename: String
    let size: Int64
    let kind: Kind
    let source: Source
}

struct FeedbackDraft {
    let description: String
    let pageURL: String
    let pageTitle: String?
    let contactEmail: String?
    let components: [FeedbackV2Metadata.Component]
    let chromiumSystemLogsText: String?
    let attachments: [FeedbackDraftAttachment]
    var previousSessionCrash: PreviousSessionCrashContext? = nil
    var inputSourceMetadata: [String: String] = [:]
}

struct FeedbackSelectedAttachmentInfo {
    let size: Int64
    let mimeType: String
    let isImage: Bool
}

enum FeedbackOutboxError: LocalizedError {
    case missingAccount
    case emptyDescription
    case invalidManifest
    case invalidAttachment(String)
    case attachmentTooLarge(String)
    case imageNormalizationFailed(String)
    case requiredAttachmentUploadFailed(String)
    case zipCreationFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingAccount:
            return "No account is available for feedback submission."
        case .emptyDescription:
            return "Feedback description is empty."
        case .invalidManifest:
            return "The feedback job could not be read."
        case .invalidAttachment(let detail):
            return detail
        case .attachmentTooLarge(let filename):
            return "\(filename) is larger than 10 MB."
        case .imageNormalizationFailed(let filename):
            return "The image attachment could not be prepared: \(filename)."
        case .requiredAttachmentUploadFailed(let filename):
            return "A required feedback attachment failed to upload: \(filename)."
        case .zipCreationFailed(let detail):
            return detail

        }
    }
}

enum FeedbackOutbox {
    static let maxSubmitAttachments = FeedbackV2Limits.attachmentCount
    static let maxLogAttachments = 5
    static let maxSentinelAttachments = 4
    static let maxSelectedAttachmentBytes: Int64 = 10 * 1024 * 1024
    static let maxAttachmentBytes = FeedbackV2Limits.attachmentBytes
    static let zipPlanningBytes: Int64 = maxAttachmentBytes - 512 * 1024
    static let maxJobRetryCount = 5
    static let archiveStrategyVersion = 7
    private static let directoryName = "feedbackOutbox"
    private static let manifestFilename = "manifest.json"
    private static let systemLogsFilename = "system_logs.txt"
    private static let primaryLogsZipFilename = "logs.zip"
    private static let sentinelLogsZipFilename = "sentinel-logs.zip"

    static func outboxRoot(for account: Account) -> URL {
        account.userDataStorage.appendingPathComponent(directoryName, isDirectory: true)
    }

    static func isImageFile(_ url: URL) -> Bool {
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
            return type.conforms(to: .image)
        }
        guard let type = UTType(filenameExtension: url.pathExtension) else {
            return false
        }
        return type.conforms(to: .image)
    }

    static func selectedAttachmentInfo(for url: URL) throws -> FeedbackSelectedAttachmentInfo {
        let values = try url.resourceValues(forKeys: [
            .contentTypeKey,
            .fileSizeKey,
            .isDirectoryKey,
            .isPackageKey,
            .isRegularFileKey,
            .isSymbolicLinkKey
        ])

        guard values.isSymbolicLink != true,
              values.isDirectory != true,
              values.isPackage != true,
              values.isRegularFile == true else {
            throw FeedbackOutboxError.invalidAttachment("Only regular files can be attached.")
        }

        let size = Int64(values.fileSize ?? 0)
        guard size <= maxSelectedAttachmentBytes else {
            throw FeedbackOutboxError.attachmentTooLarge(url.lastPathComponent)
        }

        let type = values.contentType ?? UTType(filenameExtension: url.pathExtension)
        let isImage = type?.conforms(to: .image) == true
        let mimeType = type?.preferredMIMEType ?? (isImage ? "image/png" : "application/octet-stream")
        return FeedbackSelectedAttachmentInfo(size: size, mimeType: mimeType, isImage: isImage)
    }

    static func feedbackComponents(
        extensionVersions: [String: String],
        runningSentinelInfo: SentinelHelper.RunningInfo? = SentinelHelper.runningInfo()
    ) -> [FeedbackV2Metadata.Component] {
        var components = extensionVersions.map {
            FeedbackV2Metadata.Component(
                id: $0.key,
                name: $0.key,
                type: "extension",
                version: $0.value
            )
        }

        if let sentinelComponent = sentinelComponent(from: runningSentinelInfo) {
            components.append(sentinelComponent)
        }

        return components.sorted {
            $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending
        }
    }

    private static func sentinelComponent(
        from runningInfo: SentinelHelper.RunningInfo?
    ) -> FeedbackV2Metadata.Component? {
        guard let runningInfo else { return nil }
        let version = runningInfo.version?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !version.isEmpty else { return nil }

        return FeedbackV2Metadata.Component(
            id: runningInfo.bundleID,
            name: "Phi Sentinel",
            type: "component",
            version: version
        )
    }

    @MainActor
    static func enqueue(_ draft: FeedbackDraft, account: Account) async throws {
        let jobID = UUID().uuidString
        let jobRoot = outboxRoot(for: account).appendingPathComponent(jobID, isDirectory: true)
        let metadata = makeMetadata(jobID: jobID, draft: draft)
        let serviceLogsURL = SentinelHelper.sentinelServiceLogsDirectoryURL(
            auth0Subject: account.userInfo?.sub ?? account.userID
        )
        let manifest = try await Task.detached(priority: .utility) {
            try prepareJob(draft, jobRoot: jobRoot, metadata: metadata, sentinelServiceLogsURL: serviceLogsURL)
        }.value
        do {
            guard ApplicationState.shared.isAuthenticated,
                  AccountController.shared.account?.userID == account.userID else {
                throw FeedbackOutboxError.missingAccount
            }
            // The uploader only sees complete, validated jobs. Before this atomic
            // write, a preparation error leaves the user's draft in the form.
            try writeManifest(manifest, jobRoot: jobRoot)
        } catch {
            try? FileManager.default.removeItem(at: jobRoot)
            throw error
        }
    }

    static func prepareJob(
        _ draft: FeedbackDraft,
        jobRoot: URL,
        metadata: FeedbackV2Metadata,
        phiLogsURL: URL = URL(fileURLWithPath: FileSystemUtils.phiBrowserDataDirectory(), isDirectory: true)
            .appendingPathComponent("PhiLogs", isDirectory: true),
        sentinelLogsURL: URL = SentinelHelper.sentinelLogsDirectoryURL(),
        sentinelServiceLogsURL: URL?
    ) throws -> FeedbackOutboxManifest {
        let fm = FileManager.default
        let jobID = jobRoot.lastPathComponent
        var prepared = false
        defer { if !prepared { try? fm.removeItem(at: jobRoot) } }
        let imagesDir = jobRoot.appendingPathComponent("images", isDirectory: true)
        let filesDir = jobRoot.appendingPathComponent("files", isDirectory: true)
        let logsDir = jobRoot.appendingPathComponent("logs", isDirectory: true)
        let preparedDir = jobRoot.appendingPathComponent("prepared", isDirectory: true)

        try fm.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: filesDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: logsDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: preparedDir, withIntermediateDirectories: true)

        var imageSources: [FeedbackOutboxSourceAttachment] = []
        var fileSources: [FeedbackOutboxSourceAttachment] = []
        var chromiumSystemLogs: FeedbackOutboxSourceAttachment?
        let previousSessionCrashLog = try savePreviousSessionCrashLog(draft.previousSessionCrash, jobRoot: jobRoot)

        for attachment in draft.attachments {
            switch attachment.source {
            case .pastedImage(let data):
                let filename = uniqueFilename(attachment.filename, in: imagesDir)
                let destination = imagesDir.appendingPathComponent(filename)
                try data.write(to: destination, options: .atomic)
                imageSources.append(sourceAttachment(
                    filename: filename,
                    fileURL: destination,
                    jobRoot: jobRoot,
                    mimeType: "image/png"
                ))

            case .file(let sourceURL):
                let didAccess = sourceURL.startAccessingSecurityScopedResource()
                defer {
                    if didAccess {
                        sourceURL.stopAccessingSecurityScopedResource()
                    }
                }
                let info = try selectedAttachmentInfo(for: sourceURL)
                let isImage = attachment.kind == .image || info.isImage
                let targetDirectory = isImage ? imagesDir : filesDir
                let filename = uniqueFilename(sourceURL.lastPathComponent, in: targetDirectory)
                let destination = targetDirectory.appendingPathComponent(filename)
                try fm.copyItem(at: sourceURL, to: destination)

                let source = sourceAttachment(
                    filename: filename,
                    fileURL: destination,
                    jobRoot: jobRoot,
                    mimeType: info.mimeType
                )
                if isImage {
                    imageSources.append(source)
                } else {
                    fileSources.append(source)
                }
            }
        }

        if let chromiumSystemLogsText = draft.chromiumSystemLogsText {
            let destination = logsDir.appendingPathComponent(systemLogsFilename)
            try Data(chromiumSystemLogsText.utf8).write(to: destination, options: .atomic)
            chromiumSystemLogs = sourceAttachment(
                filename: systemLogsFilename,
                fileURL: destination,
                jobRoot: jobRoot,
                mimeType: "text/plain"
            )
        }

        var manifest = FeedbackOutboxManifest(
            id: jobID,
            createdAt: Date(),
            description: draft.description,
            contactEmail: draft.contactEmail,
            metadata: metadata,
            sourceImages: imageSources,
            sourceFiles: fileSources,
            chromiumSystemLogs: chromiumSystemLogs,
            previousSessionCrashLog: previousSessionCrashLog,
            preparedAttachments: [],
            archiveStrategyVersion: archiveStrategyVersion,
            status: .queued,
            retryCount: 0,
            nextAttemptAt: nil,
            lastError: nil
        )
        manifest.logSnapshot = try captureLogSnapshot(
            jobRoot: jobRoot, chromiumSystemLogs: chromiumSystemLogs,
            previousSessionCrashLog: previousSessionCrashLog,
            phiLogsURL: phiLogsURL, sentinelLogsURL: sentinelLogsURL,
            sentinelServiceLogsURL: sentinelServiceLogsURL
        )
        manifest.preparedAttachments = try prepareAttachments(jobRoot: jobRoot, manifest: manifest)
        logSourceAttachmentDiskLocations(
            jobID: jobID,
            jobRoot: jobRoot,
            imageSources: imageSources,
            fileSources: fileSources,
            chromiumSystemLogs: chromiumSystemLogs
        )
        prepared = true
        return manifest
    }

    static func savePreviousSessionCrashLog(
        _ context: PreviousSessionCrashContext?, jobRoot: URL
    ) throws -> FeedbackOutboxSourceAttachment? {
        guard let data = context?.logSnapshot else { return nil }
        let directory = jobRoot.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("previous-session-crash.log")
        try data.write(to: url, options: .atomic)
        return sourceAttachment(filename: url.lastPathComponent, fileURL: url, jobRoot: jobRoot, mimeType: "text/plain")
    }

    fileprivate static func manifestURL(for jobRoot: URL) -> URL {
        jobRoot.appendingPathComponent(manifestFilename)
    }

    fileprivate static func readManifest(jobRoot: URL) throws -> FeedbackOutboxManifest {
        let data = try Data(contentsOf: manifestURL(for: jobRoot))
        return try JSONDecoder().decode(FeedbackOutboxManifest.self, from: data)
    }

    fileprivate static func writeManifest(_ manifest: FeedbackOutboxManifest, jobRoot: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        try data.write(to: manifestURL(for: jobRoot), options: .atomic)
    }

    fileprivate static func removePreparedDirectory(jobRoot: URL) {
        let preparedDir = jobRoot.appendingPathComponent("prepared", isDirectory: true)
        try? FileManager.default.removeItem(at: preparedDir)
    }

    static func prepareAttachments(
        jobRoot: URL,
        manifest: FeedbackOutboxManifest
    ) throws -> [FeedbackOutboxUploadAttachment] {
        let preparedDir = jobRoot.appendingPathComponent("prepared", isDirectory: true)
        try FileManager.default.createDirectory(at: preparedDir, withIntermediateDirectories: true)

        let snapshot = manifest.logSnapshot ?? legacyLogSnapshot(manifest)
        let preparedLogs = try prepareLogZipAttachments(
            jobRoot: jobRoot, preparedDir: preparedDir,
            chromiumSystemLogs: manifest.chromiumSystemLogs,
            previousSessionCrashLog: manifest.previousSessionCrashLog,
            snapshot: snapshot
        )
        let logAttachments = trimPreparedAttachments(preparedLogs, to: maxLogAttachments, jobRoot: jobRoot)
        let userSlots = maxSubmitAttachments - logAttachments.count
        let reserveFileSlot = !manifest.sourceFiles.isEmpty && userSlots > 1
        let imageAttachments = try prepareImageAttachments(
            jobRoot: jobRoot, preparedDir: preparedDir, sources: manifest.sourceImages,
            preferredSlots: userSlots - (reserveFileSlot ? 1 : 0), maxSlots: userSlots
        )
        let fileAttachments = try prepareUserFileAttachments(
            jobRoot: jobRoot, preparedDir: preparedDir, sources: manifest.sourceFiles,
            availableSlots: userSlots - imageAttachments.count
        )
        let attachments = try attachmentsWithinSubmitLimit(
            required: logAttachments + imageAttachments + fileAttachments, optional: []
        )
        logPreparedAttachmentDiskLocations(jobID: manifest.id, jobRoot: jobRoot, attachments: attachments)
        return attachments
    }

    static func prepareImageAttachments(
        jobRoot: URL,
        preparedDir: URL,
        sources: [FeedbackOutboxSourceAttachment],
        preferredSlots: Int,
        maxSlots: Int
    ) throws -> [FeedbackOutboxUploadAttachment] {
        guard !sources.isEmpty else { return [] }
        guard maxSlots > 0 else {
            AppLogWarn("Feedback V2 images skipped because no submit slots are available")
            return []
        }
        let preparedImages = try sources.map { source in
            try normalizedImageIfNeeded(
                sourceURL: jobRoot.appendingPathComponent(source.relativePath), source: source, preparedDir: preparedDir
            )
        }
        let effectivePreferredSlots = min(max(preferredSlots, 0), maxSlots)
        if preparedImages.count <= effectivePreferredSlots {
            return preparedImages.map { directImageAttachment($0, jobRoot: jobRoot) }
        }
        var directCount = effectivePreferredSlots > 1 ? min(effectivePreferredSlots - 1, preparedImages.count) : 0
        while true {
            let zipped = try makeImageZipAttachments(images: Array(preparedImages.dropFirst(directCount)), preparedDir: preparedDir)
            if directCount + zipped.count <= maxSlots {
                return preparedImages.prefix(directCount).map { directImageAttachment($0, jobRoot: jobRoot) } + zipped
            }
            // Try packing every image before dropping archives that exceed the budget.
            if directCount == 0 {
                return trimPreparedAttachments(zipped, to: maxSlots, jobRoot: jobRoot)
            }
            for attachment in zipped {
                try? FileManager.default.removeItem(at: jobRoot.appendingPathComponent(attachment.relativePath))
            }
            directCount = 0
        }
    }

    private static func directImageAttachment(_ prepared: PreparedFile, jobRoot: URL) -> FeedbackOutboxUploadAttachment {
        FeedbackOutboxUploadAttachment(
            id: UUID().uuidString,
            relativePath: prepared.url.pathRelative(to: jobRoot),
            filename: prepared.filename,
            mimeType: prepared.mimeType,
            size: prepared.size,
            attachmentType: .screenshot,
            required: true,
            status: .queued,
            retryCount: 0,
            objectKey: nil
        )
    }

    private static func makeImageZipAttachments(
        images: [PreparedFile],
        preparedDir: URL
    ) throws -> [FeedbackOutboxUploadAttachment] {
        let items = images.map { image in
            return ArchiveItem(
                sourceURL: image.url,
                inlineData: nil,
                offset: 0,
                length: UInt64(max(image.size, 0)),
                archivePath: "images/\(image.filename)"
            )
        }

        return try makeZipAttachments(
            items: items,
            preparedDir: preparedDir,
            singleFilename: "images.zip",
            numberedPrefix: "images",
            attachmentType: .screenshot,
            required: true,
            preferSingleArchiveWhenPossible: true
        )
    }

    private static func normalizedImageIfNeeded(
        sourceURL: URL,
        source: FeedbackOutboxSourceAttachment,
        preparedDir: URL
    ) throws -> PreparedFile {
        if source.size <= maxAttachmentBytes {
            return PreparedFile(url: sourceURL, filename: source.filename, mimeType: source.mimeType, size: source.size)
        }

        guard let image = NSImage(contentsOf: sourceURL),
              let data = FeedbackImageEncoder.jpegDataUnderLimit(from: image, maxBytes: maxAttachmentBytes) else {
            throw FeedbackOutboxError.imageNormalizationFailed(source.filename)
        }

        let filename = uniqueFilename(source.filename.replacingPathExtension(with: "jpg"), in: preparedDir)
        let destination = preparedDir.appendingPathComponent(filename)
        try data.write(to: destination, options: .atomic)
        return PreparedFile(url: destination, filename: filename, mimeType: "image/jpeg", size: Int64(data.count))
    }

    static func captureLogSnapshot(
        jobRoot: URL,
        chromiumSystemLogs: FeedbackOutboxSourceAttachment?,
        previousSessionCrashLog: FeedbackOutboxSourceAttachment? = nil,
        phiLogsURL: URL,
        sentinelLogsURL: URL,
        sentinelServiceLogsURL: URL?
    ) throws -> FeedbackLogSnapshot {
        var primaryItems = try collectPrimaryLogArchiveItems(
            jobRoot: jobRoot, chromiumSystemLogs: chromiumSystemLogs, phiLogsURL: phiLogsURL
        )
        if let previousSessionCrashLog {
            let url = jobRoot.appendingPathComponent(previousSessionCrashLog.relativePath)
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            primaryItems.insert(ArchiveItem(
                sourceURL: url, inlineData: nil, offset: 0, length: UInt64(size),
                archivePath: "PreviousSessionCrash/logs.txt"
            ), at: 0)
        }
        let primary = try primaryItems.map { item -> FeedbackLogSnapshot.File in
            // The previous-session crash snapshot is already bounded and immutable.
            let length = item.archivePath == "PreviousSessionCrash/logs.txt"
                ? item.length : min(item.length, UInt64(FeedbackSentinelLogCollector.perStreamBytes))
            let offset = item.offset + item.length - length
            let relativePath = "logs/primary/\(item.archivePath)"
            let destination = jobRoot.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try writeArchiveItem(ArchiveItem(
                sourceURL: item.sourceURL, inlineData: item.inlineData.map { Data($0.suffix(Int(length))) },
                offset: offset, length: length, archivePath: item.archivePath
            ), to: destination)
            let collectedBytes = fileSize(destination)
            return .init(
                archivePath: item.archivePath, relativePath: relativePath, originalBytes: Int64(item.length),
                offset: Int64(offset), collectedBytes: collectedBytes,
                truncated: collectedBytes < item.length, status: collectedBytes == 0 ? "empty" : "collected"
            )
        }
        let sentinel = try FeedbackSentinelLogCollector.collect(
            mainLogsURL: sentinelLogsURL, serviceLogsURL: sentinelServiceLogsURL, jobRoot: jobRoot
        )
        return FeedbackLogSnapshot(primary: primary, sentinel: sentinel)
    }

    /// Legacy jobs can use only their saved sources. They must not acquire logs
    /// from the session in which an older queued report happens to be retried.
    private static func legacyLogSnapshot(_ manifest: FeedbackOutboxManifest) -> FeedbackLogSnapshot {
        var primary: [FeedbackLogSnapshot.File] = []
        for (source, archivePath) in [
            (manifest.chromiumSystemLogs, "system_logs.txt"),
            (manifest.previousSessionCrashLog, "PreviousSessionCrash/logs.txt")
        ] {
            if let source {
                primary.append(.init(
                    archivePath: archivePath, relativePath: source.relativePath, originalBytes: source.size,
                    collectedBytes: source.size, status: "legacy_saved_source"
                ))
            }
        }
        return FeedbackLogSnapshot(primary: primary, sentinel: [])
    }

    static func prepareLogZipAttachments(
        jobRoot: URL,
        preparedDir: URL,
        chromiumSystemLogs: FeedbackOutboxSourceAttachment?,
        previousSessionCrashLog: FeedbackOutboxSourceAttachment? = nil,
        phiLogsURL: URL = URL(fileURLWithPath: FileSystemUtils.phiBrowserDataDirectory(), isDirectory: true)
            .appendingPathComponent("PhiLogs", isDirectory: true),
        sentinelLogsURL: URL = SentinelHelper.sentinelLogsDirectoryURL(),
        sentinelServiceLogsURL: URL? = nil,
        snapshot: FeedbackLogSnapshot? = nil
    ) throws -> [FeedbackOutboxUploadAttachment] {
        let snapshot = try snapshot ?? captureLogSnapshot(
            jobRoot: jobRoot, chromiumSystemLogs: chromiumSystemLogs,
            previousSessionCrashLog: previousSessionCrashLog, phiLogsURL: phiLogsURL,
            sentinelLogsURL: sentinelLogsURL, sentinelServiceLogsURL: sentinelServiceLogsURL
        )
        var attachments: [FeedbackOutboxUploadAttachment] = []
        if !snapshot.primary.isEmpty {
            var primary = try snapshotArchiveItems(snapshot.primary, jobRoot: jobRoot)
            primary.append(try collectionManifestItem(snapshot.primary))
            if let attachment = try makeLogZipAttachment(items: primary, preparedDir: preparedDir, filename: primaryLogsZipFilename) {
                attachments.append(attachment)
            }
        }
        if !snapshot.sentinel.isEmpty {
            attachments += try prepareSentinelZipAttachments(snapshot.sentinel, jobRoot: jobRoot, preparedDir: preparedDir)
        }
        return attachments
    }

    private static func snapshotArchiveItems(
        _ records: [FeedbackLogSnapshot.File], jobRoot: URL
    ) throws -> [ArchiveItem] {
        try records.compactMap { record in
            guard let path = record.relativePath else { return nil }
            let url = jobRoot.appendingPathComponent(path)
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size == record.collectedBytes else { throw FeedbackOutboxError.invalidManifest }
            return ArchiveItem(
                sourceURL: url, inlineData: nil, offset: 0, length: UInt64(size), archivePath: record.archivePath
            )
        }
    }

    private static func collectionManifestItem(_ records: [FeedbackLogSnapshot.File]) throws -> ArchiveItem {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(records)
        return ArchiveItem(sourceURL: nil, inlineData: data, offset: 0, length: UInt64(data.count), archivePath: "collection-manifest.json")
    }

    private static func prepareSentinelZipAttachments(
        _ records: [FeedbackLogSnapshot.File], jobRoot: URL, preparedDir: URL
    ) throws -> [FeedbackOutboxUploadAttachment] {
        let originalItems = try snapshotArchiveItems(records, jobRoot: jobRoot)
        if let single = try makeLogZipAttachment(
            items: originalItems + [collectionManifestItem(records)], preparedDir: preparedDir, filename: sentinelLogsZipFilename
        ) {
            return [single]
        }
        // Balance by bytes rather than service count. Keep each stream intact,
        // including its service directory, in one independently readable ZIP.
        for divisor in [1, 2, 4] {
            var packagedRecords = records
            let items = originalItems.map { item -> ArchiveItem in
                let length = item.length / UInt64(divisor)
                if let index = packagedRecords.firstIndex(where: { $0.archivePath == item.archivePath }) {
                    packagedRecords[index].offset += Int64(item.length - length)
                    packagedRecords[index].collectedBytes = Int64(length)
                    packagedRecords[index].truncated = packagedRecords[index].truncated || length < item.length
                }
                return ArchiveItem(
                    sourceURL: item.sourceURL, inlineData: item.inlineData,
                    offset: item.length - length, length: length, archivePath: item.archivePath
                )
            }
            let report = try collectionManifestItem(packagedRecords)
            for bucketCount in 2...maxSentinelAttachments {
                var buckets = [[ArchiveItem]](repeating: [], count: bucketCount)
                var sizes = [UInt64](repeating: 0, count: bucketCount)
                for item in items.sorted(by: { $0.length == $1.length ? $0.archivePath < $1.archivePath : $0.length > $1.length }) {
                    let index = sizes.indices.min(by: { sizes[$0] == sizes[$1] ? $0 < $1 : sizes[$0] < sizes[$1] })!
                    buckets[index].append(item)
                    sizes[index] += item.length
                }
                var attachments: [FeedbackOutboxUploadAttachment] = []
                var oversized = false
                for (index, bucket) in buckets.enumerated() where !bucket.isEmpty {
                    if let attachment = try makeLogZipAttachment(
                        items: bucket + [report], preparedDir: preparedDir, filename: "sentinel-logs-\(index + 1).zip"
                    ) {
                        attachments.append(attachment)
                    } else {
                        oversized = true
                    }
                }
                if !oversized || (divisor == 4 && bucketCount == maxSentinelAttachments) {
                    return attachments
                }
                for attachment in attachments {
                    try? FileManager.default.removeItem(at: jobRoot.appendingPathComponent(attachment.relativePath))
                }
            }
        }
        return []
    }

    private static func collectPrimaryLogArchiveItems(
        jobRoot: URL,
        chromiumSystemLogs: FeedbackOutboxSourceAttachment?,
        phiLogsURL: URL
    ) throws -> [ArchiveItem] {
        var items: [ArchiveItem] = []
        if let chromiumSystemLogs {
            let systemLogsURL = jobRoot.appendingPathComponent(chromiumSystemLogs.relativePath)
            if FileManager.default.fileExists(atPath: systemLogsURL.path) {
                items.append(chromiumSystemLogsArchiveItem(sourceURL: systemLogsURL))
            } else {
                AppLogWarn("Feedback V2 Chromium system logs file was missing when preparing logs.zip")
            }
        }

        items.append(contentsOf: try collectLatestLogArchiveItems(
            root: phiLogsURL,
            archiveRoot: "PhiLogs"
        ))
        return items
    }

    private static func makeLogZipAttachment(
        items: [ArchiveItem],
        preparedDir: URL,
        filename: String
    ) throws -> FeedbackOutboxUploadAttachment? {
        let destination = preparedDir.appendingPathComponent(filename)
        try zipArchiveItems(items, destination: destination)
        let size = fileSize(destination)
        guard size <= maxAttachmentBytes else {
            try? FileManager.default.removeItem(at: destination)
            AppLogDebug("Feedback V2 log zip needs repacking because it exceeds 20 MiB: \(filename) size=\(size)")
            return nil
        }

        return FeedbackOutboxUploadAttachment(
            id: UUID().uuidString,
            relativePath: destination.pathRelative(to: preparedDir.deletingLastPathComponent()),
            filename: filename,
            mimeType: "application/zip",
            size: size,
            attachmentType: .log,
            required: true,
            status: .queued,
            retryCount: 0,
            objectKey: nil
        )
    }

    static func prepareUserFileAttachments(
        jobRoot: URL,
        preparedDir: URL,
        sources: [FeedbackOutboxSourceAttachment],
        availableSlots: Int
    ) throws -> [FeedbackOutboxUploadAttachment] {
        guard !sources.isEmpty else { return [] }
        guard availableSlots > 0 else {
            AppLogWarn("Feedback V2 files skipped because no submit slots are available")
            return []
        }
        let attachments = try prepareUserFileZipAttachments(
            jobRoot: jobRoot, preparedDir: preparedDir, sources: sources, forceSingleArchive: true
        )
        return trimPreparedAttachments(attachments, to: availableSlots, jobRoot: jobRoot)
    }

    private static func trimPreparedAttachments(
        _ attachments: [FeedbackOutboxUploadAttachment],
        to limit: Int,
        jobRoot: URL
    ) -> [FeedbackOutboxUploadAttachment] {
        let limit = max(limit, 0)
        guard attachments.count > limit else { return attachments }
        for attachment in attachments.dropFirst(limit) {
            try? FileManager.default.removeItem(at: jobRoot.appendingPathComponent(attachment.relativePath))
        }
        AppLogWarn("Feedback V2 attachments trimmed to satisfy submit budget: kept=\(limit) total=\(attachments.count)")
        return Array(attachments.prefix(limit))
    }

    static func prepareUserFileZipAttachments(
        jobRoot: URL,
        preparedDir: URL,
        sources: [FeedbackOutboxSourceAttachment],
        forceSingleArchive: Bool
    ) throws -> [FeedbackOutboxUploadAttachment] {
        let items: [ArchiveItem] = sources.compactMap { source in
            guard source.size <= maxAttachmentBytes else {
                AppLogWarn("Feedback V2 file skipped because it exceeds 20 MiB: \(source.filename)")
                return nil
            }
            return ArchiveItem(
                sourceURL: jobRoot.appendingPathComponent(source.relativePath),
                inlineData: nil,
                offset: 0,
                length: UInt64(max(source.size, 0)),
                archivePath: source.filename
            )
        }

        guard !items.isEmpty else {
            return []
        }

        return try makeZipAttachments(
            items: items,
            preparedDir: preparedDir,
            singleFilename: forceSingleArchive ? "others.zip" : nil,
            numberedPrefix: forceSingleArchive ? "others" : "feedback-files",
            attachmentType: .other,
            required: true,
            preferSingleArchiveWhenPossible: forceSingleArchive
        )
    }

    static func attachmentsWithinSubmitLimit(
        required: [FeedbackOutboxUploadAttachment],
        optional: [FeedbackOutboxUploadAttachment]
    ) throws -> [FeedbackOutboxUploadAttachment] {
        let attachments = required + optional
        if attachments.count > maxSubmitAttachments {
            AppLogWarn("Feedback V2 attachments trimmed to satisfy submit limit: total=\(attachments.count)")
        }
        return Array(attachments.prefix(maxSubmitAttachments))
    }

    static func chromiumSystemLogsArchiveItem(sourceURL: URL) -> ArchiveItem {
        ArchiveItem(
            sourceURL: sourceURL,
            inlineData: nil,
            offset: 0,
            length: UInt64(max(fileSize(sourceURL), 0)),
            archivePath: systemLogsFilename
        )
    }

    private static func collectLatestLogArchiveItems(
        root: URL,
        archiveRoot: String
    ) throws -> [ArchiveItem] {
        let candidates = try collectLogArchiveCandidates(
            root: root,
            archiveRoot: archiveRoot
        )

        switch candidates {
        case .missing(let item), .empty(let item):
            return [item]
        case .files(let files):
            guard let latest = latestLogArchiveCandidate(in: files) else {
                let message = "\(archiveRoot) directory was empty at feedback submission time.\n"
                return [ArchiveItem(
                    sourceURL: nil,
                    inlineData: Data(message.utf8),
                    offset: 0,
                    length: UInt64(message.utf8.count),
                    archivePath: "\(archiveRoot)/empty.txt"
                )]
            }

            return [latest.archiveItem]
        }
    }

    private static func collectLogArchiveCandidates(
        root: URL,
        archiveRoot: String
    ) throws -> LogArchiveCandidates {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else {
            let message = "\(archiveRoot) directory was not found at feedback submission time.\n"
            return .missing(ArchiveItem(
                sourceURL: nil,
                inlineData: Data(message.utf8),
                offset: 0,
                length: UInt64(message.utf8.count),
                archivePath: "\(archiveRoot)/missing.txt"
            ))
        }

        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
            options: []
        ) else {
            return .files([])
        }

        var candidates: [LogArchiveCandidate] = []
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: [
                .isRegularFileKey,
                .fileSizeKey,
                .contentModificationDateKey
            ])
            guard values.isRegularFile == true else { continue }

            let relativePath = fileURL.pathRelative(to: root)
            let archivePath = "\(archiveRoot)/\(relativePath)"
            candidates.append(LogArchiveCandidate(
                url: fileURL,
                filename: fileURL.lastPathComponent,
                archivePath: archivePath,
                size: Int64(values.fileSize ?? 0),
                modificationDate: values.contentModificationDate ?? .distantPast
            ))
        }

        if candidates.isEmpty {
            let message = "\(archiveRoot) directory was empty at feedback submission time.\n"
            return .empty(ArchiveItem(
                sourceURL: nil,
                inlineData: Data(message.utf8),
                offset: 0,
                length: UInt64(message.utf8.count),
                archivePath: "\(archiveRoot)/empty.txt"
            ))
        }

        return .files(candidates)
    }

    private static func latestLogArchiveCandidate(in candidates: [LogArchiveCandidate]) -> LogArchiveCandidate? {
        candidates.sorted {
            if $0.modificationDate != $1.modificationDate {
                return $0.modificationDate > $1.modificationDate
            }
            return $0.archivePath.localizedStandardCompare($1.archivePath) == .orderedAscending
        }.first
    }

    static func collectLogArchiveItems(root: URL, archiveRoot: String) throws -> [ArchiveItem] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else {
            let message = "\(archiveRoot) directory was not found at feedback submission time.\n"
            return [ArchiveItem(
                sourceURL: nil,
                inlineData: Data(message.utf8),
                offset: 0,
                length: UInt64(message.utf8.count),
                archivePath: "\(archiveRoot)/missing.txt"
            )]
        }

        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: []
        ) else {
            return []
        }

        var items: [ArchiveItem] = []
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else { continue }

            let relativePath = fileURL.pathRelative(to: root)
            let archivePath = "\(archiveRoot)/\(relativePath)"
            let size = Int64(values.fileSize ?? 0)
            if size > zipPlanningBytes {
                var offset: UInt64 = 0
                var part = 1
                while offset < UInt64(size) {
                    let length = min(UInt64(zipPlanningBytes), UInt64(size) - offset)
                    items.append(ArchiveItem(
                        sourceURL: fileURL,
                        inlineData: nil,
                        offset: offset,
                        length: length,
                        archivePath: "\(archivePath).part-\(part)"
                    ))
                    offset += length
                    part += 1
                }
            } else {
                items.append(ArchiveItem(
                    sourceURL: fileURL,
                    inlineData: nil,
                    offset: 0,
                    length: UInt64(max(size, 0)),
                    archivePath: archivePath
                ))
            }
        }

        if items.isEmpty {
            let message = "\(archiveRoot) directory was empty at feedback submission time.\n"
            return [ArchiveItem(
                sourceURL: nil,
                inlineData: Data(message.utf8),
                offset: 0,
                length: UInt64(message.utf8.count),
                archivePath: "\(archiveRoot)/empty.txt"
            )]
        }

        return items.sorted { $0.archivePath.localizedStandardCompare($1.archivePath) == .orderedAscending }
    }

    static func makeZipAttachments(
        items: [ArchiveItem],
        preparedDir: URL,
        singleFilename: String?,
        numberedPrefix: String,
        attachmentType: FeedbackV2AttachmentType,
        required: Bool,
        preferSingleArchiveWhenPossible: Bool = false
    ) throws -> [FeedbackOutboxUploadAttachment] {
        if preferSingleArchiveWhenPossible, let singleFilename {
            let destination = preparedDir.appendingPathComponent(singleFilename)
            try zipArchiveItems(items, destination: destination)
            let size = fileSize(destination)
            if size <= maxAttachmentBytes {
                return [FeedbackOutboxUploadAttachment(
                    id: UUID().uuidString,
                    relativePath: destination.pathRelative(to: preparedDir.deletingLastPathComponent()),
                    filename: singleFilename,
                    mimeType: "application/zip",
                    size: size,
                    attachmentType: attachmentType,
                    required: required,
                    status: .queued,
                    retryCount: 0,
                    objectKey: nil
                )]
            }
            try? FileManager.default.removeItem(at: destination)
        }

        var pendingBuckets = bucketArchiveItems(items)
        var useNumberedNames = singleFilename == nil || pendingBuckets.count > 1
        var ordinal = 1
        var attachments: [FeedbackOutboxUploadAttachment] = []

        while !pendingBuckets.isEmpty {
            let bucket = pendingBuckets.removeFirst()
            let filename = useNumberedNames ? "\(numberedPrefix)-\(ordinal).zip" : (singleFilename ?? "\(numberedPrefix)-\(ordinal).zip")
            let destination = preparedDir.appendingPathComponent(filename)
            try zipArchiveItems(bucket, destination: destination)
            let size = fileSize(destination)

            if size > maxAttachmentBytes {
                try? FileManager.default.removeItem(at: destination)
                if bucket.count > 1 {
                    useNumberedNames = true
                    let midpoint = max(bucket.count / 2, 1)
                    pendingBuckets.insert(Array(bucket[midpoint...]), at: 0)
                    pendingBuckets.insert(Array(bucket[..<midpoint]), at: 0)
                    continue
                }

                let requiredText = required ? "required" : "optional"
                AppLogWarn("Feedback V2 \(requiredText) zip skipped because it exceeds 20 MB: \(filename) size=\(size)")
                continue
            }

            attachments.append(FeedbackOutboxUploadAttachment(
                id: UUID().uuidString,
                relativePath: destination.pathRelative(to: preparedDir.deletingLastPathComponent()),
                filename: filename,
                mimeType: "application/zip",
                size: size,
                attachmentType: attachmentType,
                required: required,
                status: .queued,
                retryCount: 0,
                objectKey: nil
            ))
            ordinal += 1
        }

        return attachments
    }

    static func bucketArchiveItems(_ items: [ArchiveItem]) -> [[ArchiveItem]] {
        var buckets: [[ArchiveItem]] = []
        var current: [ArchiveItem] = []
        var currentSize: Int64 = 0

        for item in items {
            let itemSize = Int64(item.length)
            if !current.isEmpty && currentSize + itemSize > zipPlanningBytes {
                buckets.append(current)
                current = []
                currentSize = 0
            }
            current.append(item)
            currentSize += itemSize
        }

        if !current.isEmpty {
            buckets.append(current)
        }
        return buckets
    }

    private static func zipArchiveItems(_ items: [ArchiveItem], destination: URL) throws {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("FeedbackZip-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        var roots = Set<String>()
        for item in items {
            let destinationURL = staging.appendingPathComponent(item.archivePath)
            try fm.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try writeArchiveItem(item, to: destinationURL)
            if let root = item.archivePath.split(separator: "/", omittingEmptySubsequences: true).first {
                roots.insert(String(root))
            }
        }

        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }

        let stderrPipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-r", "-q", destination.path] + roots.sorted()
        process.currentDirectoryURL = staging
        process.standardError = stderrPipe
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errorText = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let detail = errorText.isEmpty ? "zip exited with status \(process.terminationStatus)" : errorText
            throw FeedbackOutboxError.zipCreationFailed(detail)
        }
    }

    private static func writeArchiveItem(_ item: ArchiveItem, to destination: URL) throws {
        if let inlineData = item.inlineData {
            try inlineData.write(to: destination, options: .atomic)
            return
        }

        guard let sourceURL = item.sourceURL else {
            return
        }

        let input = try FileHandle(forReadingFrom: sourceURL)
        defer { try? input.close() }
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }

        try input.seek(toOffset: item.offset)
        var remaining = item.length
        let chunkSize = 1024 * 1024
        while remaining > 0 {
            let data = input.readData(ofLength: min(chunkSize, Int(remaining)))
            if data.isEmpty { break }
            try output.write(contentsOf: data)
            remaining -= UInt64(data.count)
        }
    }

    @MainActor
    static func currentInputSourceMetadata() -> [String: String] {
        guard let inputSource = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
            return [:]
        }

        let properties: [(String, CFString)] = [
            ("input_source_id", kTISPropertyInputSourceID),
            ("input_source_name", kTISPropertyLocalizedName)
        ]
        var metadata: [String: String] = [:]
        for (key, property) in properties {
            guard let value = TISGetInputSourceProperty(inputSource, property) else { continue }
            metadata[key] = Unmanaged<CFString>.fromOpaque(value).takeUnretainedValue() as String
        }
        return metadata
    }

    static func makeMetadata(jobID: String, draft: FeedbackDraft) -> FeedbackV2Metadata {
        FeedbackV2Metadata(
            browser: .init(
                name: "Phi Browser",
                version: SystemUtils.appVersion,
                channel: channelName,
                revision: SystemUtils.buildNumber,
                aiEnabled: PhiPreferences.AISettings.phiAIEnabled.loadValue(),
                useNTP: PhiPreferences.GeneralSettings.openNewTabPageOnCmdT.loadValue()
            ),
            page: .init(
                url: draft.pageURL.isEmpty ? nil : draft.pageURL,
                title: draft.pageTitle
            ),
            clientContext: .init(
                category: draft.previousSessionCrash == nil ? "issue-report" : "previous_session_crash",
                userAgent: nil,
                locale: Locale.current.identifier,
                traceID: jobID
            ),
            components: Array(draft.components.prefix(100)),
            extra: [
                "build_number": SystemUtils.buildNumber,
                "model_identifier": SystemUtils.modelIdentifier,
                "os_version": SystemUtils.osVersionString
            ]
                .merging(draft.inputSourceMetadata) { _, inputSourceValue in inputSourceValue }
                .merging(draft.previousSessionCrash?.metadata ?? [:]) { _, crashValue in crashValue }
        )
    }

    private static var channelName: String {
        #if NIGHTLY_BUILD
        return browserChannelName(isNightlyBuild: true, isDebugBuild: false)
        #elseif DEBUG
        return browserChannelName(isNightlyBuild: false, isDebugBuild: true)
        #else
        return browserChannelName(isNightlyBuild: false, isDebugBuild: false)
        #endif
    }

    static func browserChannelName(isNightlyBuild: Bool, isDebugBuild: Bool) -> String {
        if isNightlyBuild {
            return "canary"
        }
        if isDebugBuild {
            return "debug"
        }
        return "stable"
    }

    static func shouldDiscardFailedJob(retryCount: Int) -> Bool {
        retryCount > maxJobRetryCount
    }

    private static func sourceAttachment(
        filename: String,
        fileURL: URL,
        jobRoot: URL,
        mimeType: String
    ) -> FeedbackOutboxSourceAttachment {
        FeedbackOutboxSourceAttachment(
            relativePath: fileURL.pathRelative(to: jobRoot),
            filename: filename,
            mimeType: mimeType,
            size: fileSize(fileURL)
        )
    }

    private static func logSourceAttachmentDiskLocations(
        jobID: String,
        jobRoot: URL,
        imageSources: [FeedbackOutboxSourceAttachment],
        fileSources: [FeedbackOutboxSourceAttachment],
        chromiumSystemLogs: FeedbackOutboxSourceAttachment?
    ) {
        var entries: [String] = []
        entries.append(contentsOf: imageSources.map {
            sourceAttachmentDebugLine(kind: "source-image", source: $0, jobRoot: jobRoot)
        })
        entries.append(contentsOf: fileSources.map {
            sourceAttachmentDebugLine(kind: "source-file", source: $0, jobRoot: jobRoot)
        })
        if let chromiumSystemLogs {
            entries.append(sourceAttachmentDebugLine(
                kind: "chromium-system-logs",
                source: chromiumSystemLogs,
                jobRoot: jobRoot
            ))
        }

        let detail = entries.isEmpty ? "none" : entries.joined(separator: "\n")
        AppLogDebug("Feedback V2 source attachment disk locations: job=\(jobID) count=\(entries.count)\n\(detail)")
    }

    private static func sourceAttachmentDebugLine(
        kind: String,
        source: FeedbackOutboxSourceAttachment,
        jobRoot: URL
    ) -> String {
        let absolutePath = jobRoot.appendingPathComponent(source.relativePath).path
        return "- kind=\(kind) filename=\(source.filename) size=\(source.size) relativePath=\(source.relativePath) path=\(absolutePath)"
    }

    private static func logPreparedAttachmentDiskLocations(
        jobID: String,
        jobRoot: URL,
        attachments: [FeedbackOutboxUploadAttachment]
    ) {
        let entries = attachments.map { attachment in
            let absolutePath = jobRoot.appendingPathComponent(attachment.relativePath).path
            return "- type=\(attachment.attachmentType.rawValue) required=\(attachment.required) status=\(attachment.status.rawValue) filename=\(attachment.filename) size=\(attachment.size) relativePath=\(attachment.relativePath) path=\(absolutePath)"
        }
        let detail = entries.isEmpty ? "none" : entries.joined(separator: "\n")
        AppLogDebug("Feedback V2 prepared attachment disk locations: job=\(jobID) count=\(entries.count)\n\(detail)")
    }

    private static func mimeType(for url: URL, fallback: String) -> String {
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType,
           let mimeType = type.preferredMIMEType {
            return mimeType
        }
        if let type = UTType(filenameExtension: url.pathExtension),
           let mimeType = type.preferredMIMEType {
            return mimeType
        }
        return fallback
    }

    private static func uniqueFilename(_ originalFilename: String, in directory: URL) -> String {
        let sanitized = sanitizedFilename(originalFilename)
        let ext = (sanitized as NSString).pathExtension
        let base = (sanitized as NSString).deletingPathExtension
        var filename = sanitized
        var index = 2
        while FileManager.default.fileExists(atPath: directory.appendingPathComponent(filename).path) {
            filename = ext.isEmpty ? "\(base)-\(index)" : "\(base)-\(index).\(ext)"
            index += 1
        }
        return filename
    }

    private static func sanitizedFilename(_ filename: String) -> String {
        let illegal = CharacterSet(charactersIn: "/:\\")
        let cleaned = filename
            .components(separatedBy: illegal)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "attachment" : cleaned
    }

    private static func fileSize(_ url: URL) -> Int64 {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            return 0
        }
        return Int64(size)
    }
}

@MainActor
final class FeedbackOutboxUploader {
    static let shared = FeedbackOutboxUploader()

    private var accountObserver: NSObjectProtocol?
    private var browserAccessObserver: NSObjectProtocol?
    private var runningUserIDs = Set<String>()
    private var delayedTasks: [String: Task<Void, Never>] = [:]

    func start() {
        guard accountObserver == nil else {
            scheduleCurrentAccountProcessing()
            return
        }

        accountObserver = NotificationCenter.default.addObserver(
            forName: .mainAccountChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.scheduleCurrentAccountProcessing()
        }
        browserAccessObserver = NotificationCenter.default.addObserver(
            forName: .browserAccessStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.scheduleCurrentAccountProcessing()
        }
        scheduleCurrentAccountProcessing()
    }

    func scheduleCurrentAccountProcessing(after delay: TimeInterval = 0) {
        guard ApplicationState.shared.isAuthenticated,
              let account = AccountController.shared.account else {
            return
        }

        let userID = account.userID
        let root = FeedbackOutbox.outboxRoot(for: account)

        if delay > 0 {
            delayedTasks[userID]?.cancel()
            delayedTasks[userID] = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                await MainActor.run {
                    self?.delayedTasks[userID] = nil
                    self?.scheduleCurrentAccountProcessing()
                }
            }
            return
        }

        guard !runningUserIDs.contains(userID) else {
            return
        }

        runningUserIDs.insert(userID)
        Task.detached(priority: .utility) { [weak self] in
            let hasRetryableFailures = await Self.processOutbox(userID: userID, root: root)
            await MainActor.run {
                guard let self else { return }
                self.runningUserIDs.remove(userID)
                if hasRetryableFailures {
                    self.scheduleCurrentAccountProcessing(after: 60)
                }
            }
        }
    }

    private static func processOutbox(userID: String, root: URL) async -> Bool {
        guard await isCurrentAccount(userID) else {
            return false
        }

        let fm = FileManager.default
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            let jobRoots = try fm.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ).filter { url in
                (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            }.sorted { $0.lastPathComponent < $1.lastPathComponent }

            var hasRetryableFailures = false
            for jobRoot in jobRoots {
                guard await isCurrentAccount(userID) else {
                    return hasRetryableFailures
                }
                let retryable = await processJob(jobRoot: jobRoot, userID: userID)
                hasRetryableFailures = hasRetryableFailures || retryable
            }
            return hasRetryableFailures
        } catch {
            AppLogError("Feedback V2 outbox scan failed: \(error.localizedDescription)")
            return true
        }
    }

    private static func processJob(jobRoot: URL, userID: String) async -> Bool {
        do {
            var manifest = try FeedbackOutbox.readManifest(jobRoot: jobRoot)
            guard manifest.status != .submitted else {
                return false
            }
            if let nextAttemptAt = manifest.nextAttemptAt, nextAttemptAt > Date() {
                return true
            }
            if FeedbackOutbox.shouldDiscardFailedJob(retryCount: manifest.retryCount) {
                AppLogError("Feedback V2 job discarded because retry limit was already exceeded: job=\(manifest.id) retryCount=\(manifest.retryCount)")
                try? FileManager.default.removeItem(at: jobRoot)
                return false
            }

            guard await isCurrentAccount(userID) else {
                return false
            }

            do {
                if manifest.logSnapshot != nil, manifest.archiveStrategyVersion != FeedbackOutbox.archiveStrategyVersion {
                    AppLogInfo("Feedback V2 archive strategy changed; preparing job again: \(manifest.id)")
                    FeedbackOutbox.removePreparedDirectory(jobRoot: jobRoot)
                    manifest.preparedAttachments = []
                    manifest.archiveStrategyVersion = FeedbackOutbox.archiveStrategyVersion
                }

                if !manifest.preparedAttachments.isEmpty,
                   !preparedFilesExist(jobRoot: jobRoot, manifest: manifest) {
                    AppLogWarn("Feedback V2 prepared files are incomplete; preparing job again: \(manifest.id)")
                    FeedbackOutbox.removePreparedDirectory(jobRoot: jobRoot)
                    manifest.preparedAttachments = []
                }

                if manifest.preparedAttachments.isEmpty {
                    manifest.status = .preparing
                    manifest.lastError = nil
                    try FeedbackOutbox.writeManifest(manifest, jobRoot: jobRoot)
                    manifest.preparedAttachments = try FeedbackOutbox.prepareAttachments(
                        jobRoot: jobRoot,
                        manifest: manifest
                    )
                    manifest.archiveStrategyVersion = FeedbackOutbox.archiveStrategyVersion
                    try FeedbackOutbox.writeManifest(manifest, jobRoot: jobRoot)
                }

                manifest.status = .uploading
                manifest.lastError = nil
                try FeedbackOutbox.writeManifest(manifest, jobRoot: jobRoot)

                try await uploadAttachments(jobRoot: jobRoot, manifest: &manifest, userID: userID)

                guard manifest.preparedAttachments.filter(\.required).allSatisfy({ $0.status == .uploaded }) else {
                    throw FeedbackOutboxError.requiredAttachmentUploadFailed("required attachments")
                }

                guard await isCurrentAccount(userID) else {
                    return false
                }

                manifest.status = .submitting
                try FeedbackOutbox.writeManifest(manifest, jobRoot: jobRoot)

                let submitAttachments = manifest.preparedAttachments.compactMap(\.submitAttachment)
                let response = try await retrying {
                    try await APIClient.shared.submitFeedbackV2(FeedbackV2SubmitRequest(
                        description: manifest.description,
                        contactEmail: manifest.contactEmail,
                        metadata: manifest.metadata,
                        attachments: submitAttachments
                    ))
                }

                AppLogInfo("Feedback V2 submitted: job=\(manifest.id) feedbackID=\(response.data.feedbackID)")
                manifest.status = .submitted
                manifest.nextAttemptAt = nil
                manifest.lastError = nil
                try FeedbackOutbox.writeManifest(manifest, jobRoot: jobRoot)
                try? FileManager.default.removeItem(at: jobRoot)
                return false
            } catch {
                manifest.status = .failedWaitingRetry
                manifest.retryCount += 1
                manifest.lastError = error.localizedDescription
                if FeedbackOutbox.shouldDiscardFailedJob(retryCount: manifest.retryCount) {
                    AppLogError("Feedback V2 job discarded after retry limit: job=\(manifest.id) retryCount=\(manifest.retryCount) error=\(error.localizedDescription)")
                    try? FileManager.default.removeItem(at: jobRoot)
                    return false
                }

                manifest.nextAttemptAt = Date().addingTimeInterval(backoffDelay(for: manifest.retryCount))
                try? FeedbackOutbox.writeManifest(manifest, jobRoot: jobRoot)
                AppLogError("Feedback V2 job failed and will retry: job=\(manifest.id) error=\(error.localizedDescription)")
                return true
            }
        } catch {
            AppLogError("Feedback V2 job ignored because manifest is unreadable: \(jobRoot.path) error=\(error.localizedDescription)")
            return false
        }
    }

    private static func uploadAttachments(
        jobRoot: URL,
        manifest: inout FeedbackOutboxManifest,
        userID: String
    ) async throws {
        let requiredIndices = manifest.preparedAttachments.indices.filter {
            manifest.preparedAttachments[$0].required && manifest.preparedAttachments[$0].status != .uploaded
        }
        try await uploadBatches(indices: requiredIndices, jobRoot: jobRoot, manifest: &manifest, userID: userID, requiredBatch: true)

        let optionalIndices = manifest.preparedAttachments.indices.filter {
            !manifest.preparedAttachments[$0].required && manifest.preparedAttachments[$0].status != .uploaded
        }
        try await uploadBatches(indices: optionalIndices, jobRoot: jobRoot, manifest: &manifest, userID: userID, requiredBatch: false)
    }

    private static func uploadBatches(
        indices: [Array<FeedbackOutboxUploadAttachment>.Index],
        jobRoot: URL,
        manifest: inout FeedbackOutboxManifest,
        userID: String,
        requiredBatch: Bool
    ) async throws {
        for batch in indices.chunked(into: FeedbackV2Limits.attachmentCount) {
            guard await isCurrentAccount(userID) else {
                throw FeedbackOutboxError.requiredAttachmentUploadFailed("account changed")
            }

            let requests = batch.map { manifest.preparedAttachments[$0].presignRequest }
            let presignedAttachments: [FeedbackV2PresignedAttachment]
            do {
                presignedAttachments = try await retrying {
                    try await APIClient.shared.presignFeedbackV2Attachments(requests)
                }
                guard presignedAttachments.count == batch.count else {
                    throw APIError.invalidResponse
                }
            } catch {
                if requiredBatch {
                    throw error
                }
                for index in batch {
                    var attachment = manifest.preparedAttachments[index]
                    attachment.retryCount += 1
                    attachment.status = .failed
                    manifest.preparedAttachments[index] = attachment
                }
                try? FeedbackOutbox.writeManifest(manifest, jobRoot: jobRoot)
                AppLogWarn("Feedback V2 optional attachment batch skipped after presign retry: \(error.localizedDescription)")
                continue
            }

            for (batchPosition, index) in batch.enumerated() {
                var attachment = manifest.preparedAttachments[index]
                let presigned = presignedAttachments[batchPosition]
                do {
                    try await retrying(attempts: 2) {
                        try await upload(attachment, presigned: presigned, jobRoot: jobRoot)
                    }
                    attachment.status = .uploaded
                    attachment.objectKey = presigned.objectKey
                    attachment.retryCount = 0
                } catch {
                    do {
                        let freshObjectKey = try await uploadWithFreshPresign(attachment, jobRoot: jobRoot)
                        attachment.status = .uploaded
                        attachment.objectKey = freshObjectKey
                        attachment.retryCount = 0
                    } catch {
                        attachment.retryCount += 1
                        attachment.status = .failed
                        manifest.preparedAttachments[index] = attachment
                        try? FeedbackOutbox.writeManifest(manifest, jobRoot: jobRoot)
                        if attachment.required {
                            throw FeedbackOutboxError.requiredAttachmentUploadFailed(attachment.filename)
                        }
                        AppLogWarn("Feedback V2 optional attachment skipped after upload retry: \(attachment.filename)")
                        continue
                    }
                }

                manifest.preparedAttachments[index] = attachment
                try FeedbackOutbox.writeManifest(manifest, jobRoot: jobRoot)
            }
        }
    }

    private static func preparedFilesExist(jobRoot: URL, manifest: FeedbackOutboxManifest) -> Bool {
        manifest.preparedAttachments.allSatisfy {
            FileManager.default.fileExists(atPath: jobRoot.appendingPathComponent($0.relativePath).path)
        }
    }

    private static func uploadWithFreshPresign(
        _ attachment: FeedbackOutboxUploadAttachment,
        jobRoot: URL
    ) async throws -> String {
        let presigned = try await retrying {
            try await APIClient.shared.presignFeedbackV2Attachments([attachment.presignRequest])
        }
        guard let first = presigned.first else {
            throw APIError.invalidResponse
        }
        try await retrying(attempts: 2) {
            try await upload(attachment, presigned: first, jobRoot: jobRoot)
        }
        return first.objectKey
    }

    private static func upload(
        _ attachment: FeedbackOutboxUploadAttachment,
        presigned: FeedbackV2PresignedAttachment,
        jobRoot: URL
    ) async throws {
        try await APIClient.shared.uploadFeedbackV2Attachment(
            fileURL: jobRoot.appendingPathComponent(attachment.relativePath),
            mimeType: attachment.mimeType,
            presignedAttachment: presigned
        )
    }

    private static func retrying<T>(
        attempts: Int = 3,
        operation: () async throws -> T
    ) async throws -> T {
        var lastError: Error?
        for attempt in 1...attempts {
            do {
                return try await operation()
            } catch {
                lastError = error
                if attempt < attempts {
                    try? await Task.sleep(nanoseconds: UInt64(attempt * 2) * 1_000_000_000)
                }
            }
        }
        throw lastError ?? APIError.invalidResponse
    }

    private static func backoffDelay(for retryCount: Int) -> TimeInterval {
        min(3600, pow(2.0, Double(min(retryCount, 6))) * 30)
    }

    private static func isCurrentAccount(_ userID: String) async -> Bool {
        await MainActor.run {
            AccountController.shared.account?.userID == userID
        }
    }
}

struct FeedbackOutboxManifest: Codable {
    enum Status: String, Codable {
        case queued
        case preparing
        case uploading
        case submitting
        case submitted
        case failedWaitingRetry
    }

    var id: String
    var createdAt: Date
    var description: String
    var contactEmail: String?
    var metadata: FeedbackV2Metadata
    var sourceImages: [FeedbackOutboxSourceAttachment]
    var sourceFiles: [FeedbackOutboxSourceAttachment]
    var chromiumSystemLogs: FeedbackOutboxSourceAttachment?
    var previousSessionCrashLog: FeedbackOutboxSourceAttachment? = nil
    var preparedAttachments: [FeedbackOutboxUploadAttachment]
    var archiveStrategyVersion: Int?
    var status: Status
    var retryCount: Int
    var nextAttemptAt: Date?
    var lastError: String?
    var logSnapshot: FeedbackLogSnapshot? = nil
}

struct FeedbackOutboxSourceAttachment: Codable {
    let relativePath: String
    let filename: String
    let mimeType: String
    let size: Int64
}

struct FeedbackOutboxUploadAttachment: Codable, Identifiable {
    enum UploadStatus: String, Codable {
        case queued
        case uploaded
        case failed
    }

    var id: String
    var relativePath: String
    var filename: String
    var mimeType: String
    var size: Int64
    var attachmentType: FeedbackV2AttachmentType
    var required: Bool
    var status: UploadStatus
    var retryCount: Int
    var objectKey: String?

    var presignRequest: FeedbackV2PresignAttachmentRequest {
        FeedbackV2PresignAttachmentRequest(
            filename: filename,
            mimeType: mimeType,
            size: size,
            attachmentType: attachmentType
        )
    }

    var submitAttachment: FeedbackV2SubmitAttachment? {
        guard status == .uploaded, let objectKey else {
            return nil
        }
        return FeedbackV2SubmitAttachment(
            objectKey: objectKey,
            filename: filename,
            mimeType: mimeType,
            size: size,
            attachmentType: attachmentType
        )
    }
}

private struct PreparedFile {
    let url: URL
    let filename: String
    let mimeType: String
    let size: Int64
}

struct ArchiveItem {
    let sourceURL: URL?
    let inlineData: Data?
    let offset: UInt64
    let length: UInt64
    let archivePath: String
}

private enum LogArchiveCandidates {
    case missing(ArchiveItem)
    case empty(ArchiveItem)
    case files([LogArchiveCandidate])
}

private struct LogArchiveCandidate {
    let url: URL
    let filename: String
    let archivePath: String
    let size: Int64
    let modificationDate: Date

    var archiveItem: ArchiveItem {
        ArchiveItem(
            sourceURL: url,
            inlineData: nil,
            offset: 0,
            length: UInt64(max(size, 0)),
            archivePath: archivePath
        )
    }
}

private enum FeedbackImageEncoder {
    static func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else {
            return nil
        }
        return bitmap.representation(using: .png, properties: [:])
    }

    static func jpegDataUnderLimit(from image: NSImage, maxBytes: Int64) -> Data? {
        let dimensions: [CGFloat] = [8192, 6144, 4096, 3072, 2048, 1536, 1024]
        let qualities: [CGFloat] = [0.92, 0.82, 0.72, 0.62, 0.52, 0.42]

        for dimension in dimensions {
            let scaledImage = image.scaledDown(maxDimension: dimension)
            for quality in qualities {
                guard let data = jpegData(from: scaledImage, quality: quality) else {
                    continue
                }
                if Int64(data.count) <= maxBytes {
                    return data
                }
            }
        }
        return nil
    }

    private static func jpegData(from image: NSImage, quality: CGFloat) -> Data? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: quality])
    }
}

private extension NSImage {
    func scaledDown(maxDimension: CGFloat) -> NSImage {
        let longest = max(size.width, size.height)
        guard longest > maxDimension, longest > 0 else {
            return self
        }

        let ratio = maxDimension / longest
        let targetSize = NSSize(width: size.width * ratio, height: size.height * ratio)
        let image = NSImage(size: targetSize)
        image.lockFocus()
        draw(
            in: NSRect(origin: .zero, size: targetSize),
            from: NSRect(origin: .zero, size: size),
            operation: .copy,
            fraction: 1
        )
        image.unlockFocus()
        return image
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else {
            return [self]
        }
        var chunks: [[Element]] = []
        var index = startIndex
        while index < endIndex {
            let end = self.index(index, offsetBy: size, limitedBy: endIndex) ?? endIndex
            chunks.append(Array(self[index..<end]))
            index = end
        }
        return chunks
    }
}

private extension String {
    func replacingPathExtension(with newExtension: String) -> String {
        let nsString = self as NSString
        let base = nsString.deletingPathExtension
        return newExtension.isEmpty ? base : "\(base).\(newExtension)"
    }
}

private extension URL {
    func pathRelative(to baseURL: URL) -> String {
        let basePath = baseURL.standardizedFileURL.path
        let path = standardizedFileURL.path
        guard path.hasPrefix(basePath) else {
            return lastPathComponent
        }
        var relative = String(path.dropFirst(basePath.count))
        if relative.hasPrefix("/") {
            relative.removeFirst()
        }
        return relative
    }
}

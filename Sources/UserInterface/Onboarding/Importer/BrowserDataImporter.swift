// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import Combine
import CoreData
class BrowserDataImporter {
    enum Phase {
        case waiting
        case importingChromeData
        case importingSafariData
        case importingArcData
        case importingFile
        case done
    }

    struct ChromiumProfileInfo: Equatable {
        let directory: String
        let name: String
        let email: String?
    }

    private(set) var targetProfileId: String
    private(set) var targetSpaceId: String
    private(set) var targetWindowId: Int?

    /// True from the moment an import starts until its deferred bookmark
    /// persistence finishes. While true the target must not be rebound, or the
    /// pending snapshot would be saved into the newly-bound Space instead of
    /// the one the running import was started for.
    private(set) var isImporting = false

    // Continuations for active import requests, keyed by browser type.
    private var importContinuations: [BrowserType: CheckedContinuation<Bool, Never>] = [:]
    private let continuationQueue = DispatchQueue(label: "com.phibrowser.import.continuation")
    
    private(set) var failedImports: [BrowserType] = []
    @Published private(set) var phase: Phase = .waiting
    @Published var status: String = ""
    
    init(targetProfileId: String = LocalStore.defaultProfileId, targetSpaceId: String = LocalStore.defaultSpaceId, targetWindowId: Int? = nil) {
        self.targetProfileId = targetProfileId
        self.targetSpaceId = targetSpaceId
        self.targetWindowId = targetWindowId
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleImportCompleted(_:)),
            name: .browserImportCompleted,
            object: nil
        )
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Retargets a future import to a different window/profile/Space when the
    /// single import window is re-invoked from another Space. Callers must skip
    /// this while `isImporting` is true so the in-flight import keeps its
    /// original destination.
    func updateTarget(profileId: String, spaceId: String, windowId: Int?) {
        targetProfileId = profileId
        targetSpaceId = spaceId
        targetWindowId = windowId
    }

    /// The Arc Space bookmark root to persist, or nil. Gated on Arc actually being
    /// among the selected browsers (defense in depth: never write Arc bookmarks for a
    /// Chrome/Safari-only import even if an Arc space is cached), bookmarks being
    /// requested for Arc, and a space being chosen.
    static func arcBookmarkRoot(
        options: [BrowserType],
        arcSpace: ArcSpace?,
        wantsBookmarks: Bool
    ) -> ArcDataParserTool.Bookmark? {
        guard options.contains(.arc), let arcSpace, wantsBookmarks else { return nil }
        return arcSpace.root
    }

    /// Starts importing data from the selected browsers. Returns `false` only
    /// when the call was ignored because an import is already in flight, so the
    /// caller can skip its completion handler instead of advancing/closing the
    /// UI out from under the running import.
    @MainActor
    @discardableResult
    func startImportData(
        _ options: [BrowserType],
        chromeProfileDirectory: String? = nil,
        arcSpace: ArcSpace? = nil,
        dataTypesPerBrowser: [BrowserType: [String]]? = nil,
        importFilePath: String? = nil
    ) async -> Bool {
        // Prefer the caller-provided window so Chromium import state follows the initiating window/profile.
        guard let windowId = targetWindowId ?? MainBrowserWindowControllersManager.shared.getFirstAvailableWindowId() else {
            AppLogError("No available window for import")
            return true
        }

        // Reentrancy gate: a second start (rapid double-click, repeated action
        // dispatch, programmatic re-call) while an import is unresolved would
        // overwrite the BrowserType-keyed continuation and race the shared
        // Chromium bookmark staging. @MainActor plus setting the flag with no
        // preceding await makes this check atomic against a queued second call.
        // Returning false lets the caller skip its completion for this ignored start.
        guard !isImporting else {
            AppLogInfo("Import already in progress; ignoring re-entrant start")
            return false
        }
        isImporting = true
        let lockedSpaceId = targetSpaceId
        ImportTargetLock.shared.begin(into: lockedSpaceId)
        failedImports.removeAll()

        // Validate the file source before any destructive work: if its path is
        // missing/unreadable (the file was moved or deleted after picking, or a nil
        // path reached us from a programmatic caller), drop `.file` so we neither
        // clear the Chromium bookmark staging below nor start an import that can't
        // succeed. Surface it as a failed import so the skip isn't silent.
        var options = options
        if options.contains(.file) {
            let readable = importFilePath.map {
                !$0.isEmpty && FileManager.default.isReadableFile(atPath: $0)
            } ?? false
            if !readable {
                AppLogWarn("File import skipped: no readable file at \(importFilePath ?? "nil")")
                options.removeAll { $0 == .file }
                failedImports.append(.file)
            }
        }

        // Only clear bookmarks if at least one browser is importing bookmarks
        let importingBookmarks = options.contains { option in
            guard let types = dataTypesPerBrowser?[option] else { return true } // nil = import all
            return types.contains(ImportDataType.bookmarks.rawValue)
        }
        if importingBookmarks {
            ChromiumLauncher.sharedInstance().bridge?.removeAllBookmarks(withWindowId: windowId.int64Value)
        }

        for option in options {
            updatePhase(option)

            // For Arc, bookmarks are handled separately via ArcDataParserTool.
            // Only send non-bookmark types to the bridge.
            var bridgeDataTypes = dataTypesPerBrowser?[option]
            if option == .arc {
                bridgeDataTypes = bridgeDataTypes?.filter { $0 != ImportDataType.bookmarks.rawValue }
            }

            let sourceProfileDirectory: String?
            switch option {
            case .chrome: sourceProfileDirectory = chromeProfileDirectory
            case .arc:    sourceProfileDirectory = arcSpace?.profile.directoryName
            default:      sourceProfileDirectory = nil
            }
            // .unknown Arc profile (nil dir) → bookmarks only; never import Default's data.
            let arcDataImportable = option != .arc || sourceProfileDirectory != nil
            if (option != .arc || !(bridgeDataTypes?.isEmpty ?? true)), arcDataImportable {
                let success = await importData(option, windowId: windowId,
                    sourceProfileDirectory: sourceProfileDirectory, dataTypes: bridgeDataTypes,
                    importFilePath: importFilePath)
                if !success { failedImports.append(option) }
                AppLogInfo("Import from \(option) completed with success: \(success)")
            } else if option == .arc, !arcDataImportable, !(bridgeDataTypes?.isEmpty ?? true) {
                // Deliberate, safe skip: the chosen Space's profile is unresolved
                // (.unknown), so we import its bookmarks only and never fall back to
                // Default's data. Surface it so the skip isn't silent.
                AppLogWarn("Arc data import skipped for unresolved source profile; imported bookmarks only")
            }
        }

        let arcWantsBookmarks = dataTypesPerBrowser?[.arc]?.contains(ImportDataType.bookmarks.rawValue) ?? true
        let arcSpaceRoot = Self.arcBookmarkRoot(options: options, arcSpace: arcSpace, wantsBookmarks: arcWantsBookmarks)

        updateCompletionStatus()

        if importingBookmarks || arcSpaceRoot != nil {
            Task { [weak self] in
                if let self {
                    await self.persistImportedBookmarksAfterSnapshot(
                        windowId: windowId,
                        arcSpaceRoot: arcSpaceRoot
                    )
                    await MainActor.run { self.isImporting = false }
                }
                // Release the Space lock even if the importer was deallocated
                // (its window can close right after startImportData returns);
                // otherwise the Space stays locked until restart. `lockedSpaceId`
                // is value-captured and the lock is global, so this needs no self.
                ImportTargetLock.shared.end(into: lockedSpaceId)
            }
        } else {
            isImporting = false
            ImportTargetLock.shared.end(into: lockedSpaceId)
        }

        return true
    }
    
    
    private func getArcSidebarData() -> Data? {
         let localStateURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Arc/StorableSidebar.json")
        return try? Data(contentsOf: localStateURL)
    }

    /// Returns all Arc Spaces from StorableSidebar.json, sorted by title.
    /// Used by the import picker to let the user choose which Space to import.
    func loadArcSpaces() -> [ArcSpace] {
        guard let data = getArcSidebarData() else { return [] }
        return (try? ArcDataParserTool.parse(data: data)) ?? []
    }
    
    /// Imports data for one browser using a continuation-backed async flow.
    private func importData(
        _ option: BrowserType,
        windowId: Int,
        sourceProfileDirectory: String?,
        dataTypes: [String]?,
        importFilePath: String? = nil
    ) async -> Bool {
        return await withCheckedContinuation { continuation in
            continuationQueue.async { [weak self] in
                guard let self = self else {
                    continuation.resume(returning: false)
                    return
                }

                self.importContinuations[option] = continuation

                DispatchQueue.main.async {
                    if option == .file {
                        // File import: Chromium sniffs the file type + parses it, staging
                        // the result into its BookmarkModel to be pulled back like the
                        // browser sources. Completion arrives via importCompleted(.file).
                        ChromiumLauncher.sharedInstance().bridge?.importData(
                            fromFilePath: importFilePath ?? "",
                            windowId: Int64(windowId)
                        )
                    } else {
                        let profile = sourceProfileDirectory ?? ""
                        ChromiumLauncher.sharedInstance().bridge?.importBrowserData(
                            from: option,
                            profile: profile,
                            dataTypes: dataTypes,
                            windowId: Int64(windowId)
                        )
                    }
                }
            }
        }
    }
    
    /// Handles the completion callback emitted by the Chromium bridge.
    @objc private func handleImportCompleted(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let browserTypeRaw = userInfo["browserType"] as? UInt,
              let browserType = BrowserType(rawValue: browserTypeRaw),
              let success = userInfo["success"] as? Bool else {
            AppLogError("Invalid import completion notification")
            return
        }
        
        continuationQueue.async { [weak self] in
            guard let self = self,
                  let continuation = self.importContinuations.removeValue(forKey: browserType) else {
                AppLogError("No continuation found for browser type: \(browserType)")
                return
            }
            
            continuation.resume(returning: success)
        }
    }
    
    /// Updates the current import phase and status text.
    private func updatePhase(_ option: BrowserType) {
        switch option {
        case .arc:
            phase = .importingArcData
            status = NSLocalizedString("oobe.importBrowserData.progress.importingArc", value: "Importing Arc data...", comment: "Browser data importer - Status message while importing Arc browser data")
        case .chrome:
            phase = .importingChromeData
            status = NSLocalizedString("oobe.importBrowserData.progress.importingChrome", value: "Importing Chrome data...", comment: "Browser data importer - Status message while importing Chrome browser data")
        case .safari:
            phase = .importingSafariData
            status = NSLocalizedString("oobe.importBrowserData.progress.importingSafari", value: "Importing Safari data...", comment: "Browser data importer - Status message while importing Safari browser data")
        case .file:
            phase = .importingFile
            status = NSLocalizedString("oobe.importBrowserData.progress.importingFile", value: "Importing data from file...", comment: "Browser data importer - Status message while importing data from a file")
        @unknown default:
            phase = .waiting
            status = ""
        }
    }
    
    private func updateCompletionStatus() {
        phase = .done
        if failedImports.isEmpty {
            status = NSLocalizedString("oobe.importBrowserData.progress.completed", value: "Import completed successfully", comment: "Browser data importer - Status message when all imports completed successfully")
        } else {
            let failedBrowserNames = failedImports.map { browserName(for: $0) }.joined(separator: ", ")
            let format = NSLocalizedString("oobe.importBrowserData.progress.completedWithErrors", value: "Import completed with errors. Failed to import from: %@", comment: "Browser data importer - Status message when some imports failed, shows list of failed browsers")
            status = String(format: format, failedBrowserNames)
        }
    }
    
    /// Returns the user-facing browser name.
    private func browserName(for type: BrowserType) -> String {
        switch type {
        case .chrome:
            return "Chrome"
        case .safari:
            return "Safari"
        case .arc:
            return "Arc"
        case .file:
            return "File"
        @unknown default:
            return "Unknown"
        }
    }

    private func persistImportedBookmarksAfterSnapshot(
        windowId: Int,
        arcSpaceRoot: ArcDataParserTool.Bookmark?
    ) async {
        try? await Task.sleep(nanoseconds: 3 * 1_000_000_000)

        let bookmarkWrappers = await MainActor.run {
            ChromiumLauncher.sharedInstance().bridge?.getAllBookmarks(withWindowId: windowId.int64Value)
        }

        await AccountController.shared.account?.localStorage.saveChromiumBookmarksToLocalStore(
            bookmarkWrappers ?? [], profileId: targetProfileId, spaceId: targetSpaceId)

        if let arcSpaceRoot {
            await AccountController.shared.account?.localStorage.saveArcBookmarksToLocalStore(
                arcSpaceRoot, profileId: targetProfileId, spaceId: targetSpaceId)
        }

        await AccountController.shared.account?.localStorage.reorderImportedBrowserFolders(
            profileId: targetProfileId, spaceId: targetSpaceId)
    }

    func loadChromiumProfiles(
        localStateURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Google/Chrome/Local State")
    ) -> [ChromiumProfileInfo] {
        guard let data = try? Data(contentsOf: localStateURL) else {
            AppLogError("Unable to read Local State at \(localStateURL.path)")
            return []
        }
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let profile = root["profile"] as? [String: Any],
            let infoCache = profile["info_cache"] as? [String: Any],
            let profilesOrder = profile["profiles_order"] as? [String]
        else {
            AppLogError("Invalid Local State profile structure")
            return []
        }

        var results: [ChromiumProfileInfo] = []
        results.reserveCapacity(profilesOrder.count)
        for directory in profilesOrder {
            guard let info = infoCache[directory] as? [String: Any] else {
                continue
            }
            let name = (info["name"] as? String) ?? directory
            let email = info["user_name"] as? String
            results.append(ChromiumProfileInfo(directory: directory, name: name, email: email))
        }

        return results
    }
}

// MARK: - Notification Name
extension Notification.Name {
    static let browserImportCompleted = Notification.Name("browserImportCompleted")
}

/// Tracks which Spaces currently have an import writing into them so a Space
/// can't be deleted out from under an in-flight import — which would otherwise
/// strand the imported bookmarks under an orphan root (the persist path also
/// revalidates the Space as a backstop). The importer brackets this around its
/// `isImporting` window. Lock-guarded rather than actor-isolated so the
/// non-isolated `SpaceManager.deleteSpace` can consult it synchronously.
final class ImportTargetLock {
    static let shared = ImportTargetLock()
    private let lock = NSLock()
    private var importingSpaceIds: Set<String> = []
    private init() {}

    func begin(into spaceId: String) {
        lock.lock(); defer { lock.unlock() }
        importingSpaceIds.insert(spaceId)
    }

    func end(into spaceId: String) {
        lock.lock(); defer { lock.unlock() }
        importingSpaceIds.remove(spaceId)
    }

    func isImporting(into spaceId: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return importingSpaceIds.contains(spaceId)
    }
}

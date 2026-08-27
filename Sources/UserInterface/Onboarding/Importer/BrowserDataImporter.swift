// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import Combine
import PostHog
import SwiftData

struct BrowserImportAnalytics {
    enum ErrorCode: String {
        case noWindow = "no_window"
        case bridgeUnavailable = "bridge_unavailable"
        case fileUnreadable = "file_unreadable"
        case sourceImportFailed = "source_import_failed"
        case bookmarkPersistenceFailed = "bookmark_persistence_failed"
    }

    typealias Capture = (_ event: String, _ properties: [String: Any]) -> Void

    private let capture: Capture

    init(capture: @escaping Capture = { event, properties in
        PostHogSDK.shared.capture(event, properties: properties)
    }) {
        self.capture = capture
    }

    func captureMenuPresentation() {
        capture("import_viewed", ["entry_point": "menu"])
    }

    func captureSelections(
        sources: [BrowserType],
        dataTypesPerBrowser: [BrowserType: [String]]?
    ) {
        for source in Self.sortedSources(sources) {
            let selectedTypes: [String]
            if source == .file {
                selectedTypes = []
            } else if let wireTypes = dataTypesPerBrowser?[source] {
                selectedTypes = Self.normalizedDataTypes(wireTypes)
            } else {
                selectedTypes = Self.normalizedDataTypes(
                    ImportDataType.availableTypes(for: source).map(\.rawValue)
                )
            }
            capture("import_types_selected", [
                "source_browser": Self.sourceName(source),
                "types": selectedTypes,
            ])
        }
    }

    func captureStarted(sources: [BrowserType]) {
        capture("import_started", [
            "source_browsers": Self.sourceNames(sources),
        ])
    }

    func captureFinished(
        sources: [BrowserType],
        failedSources: [BrowserType],
        duration: TimeInterval,
        errorCode: ErrorCode?
    ) {
        let failedSourceNames = Self.sourceNames(failedSources)
        var properties: [String: Any] = [
            "source_browsers": Self.sourceNames(sources),
            "success": failedSourceNames.isEmpty,
            "failed_sources": failedSourceNames,
            "duration_seconds": max(0, duration),
        ]
        if let errorCode {
            properties["error_code"] = errorCode.rawValue
        }
        capture("import_finished", properties)
    }

    static func sourceNames(_ sources: [BrowserType]) -> [String] {
        sortedSources(sources).map(sourceName)
    }

    static func normalizedDataTypes(_ wireTypes: [String]) -> [String] {
        Array(Set(wireTypes.compactMap { wireType in
            switch wireType {
            case ImportDataType.bookmarks.rawValue:
                return "bookmarks"
            case ImportDataType.history.rawValue:
                return "history"
            case ImportDataType.cookies.rawValue:
                return "cookies"
            case ImportDataType.extensions.rawValue:
                return "extensions"
            default:
                return nil
            }
        })).sorted()
    }

    static func sourceName(_ source: BrowserType) -> String {
        switch source {
        case .chrome:
            return "chrome"
        case .safari:
            return "safari"
        case .arc:
            return "arc"
        case .file:
            return "file"
        @unknown default:
            return "unknown"
        }
    }

    private static func sortedSources(
        _ sources: [BrowserType]
    ) -> [BrowserType] {
        var seen = Set<String>()
        return sources.sorted {
            sourceName($0) < sourceName($1)
        }.filter {
            seen.insert(sourceName($0)).inserted
        }
    }
}

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
    private var importContinuations: [
        BrowserType: CheckedContinuation<SourceImportResult, Never>
    ] = [:]
    private let continuationQueue = DispatchQueue(label: "com.phibrowser.import.continuation")
    
    private(set) var failedImports: [BrowserType] = []
    @Published private(set) var phase: Phase = .waiting
    @Published var status: String = ""
    
    /// Resolves the store imported bookmarks are written into. Guest Mode routes
    /// Spaces, bookmarks, and pinned tabs through the stable default account
    /// rather than a published identity, so this must resolve the same way the
    /// rest of the browser does and must not depend on a signed-in account.
    private let localDataStoreProvider: () -> LocalStore?
    private let analytics: BrowserImportAnalytics

    init(targetProfileId: String = LocalStore.defaultProfileId,
         targetSpaceId: String = LocalStore.defaultSpaceId,
         targetWindowId: Int? = nil,
         localDataStoreProvider: @escaping () -> LocalStore? = {
             AccountController.shared.localDataAccount?.localStorage
         },
         analyticsCapture: @escaping BrowserImportAnalytics.Capture = {
             event, properties in
             PostHogSDK.shared.capture(event, properties: properties)
         }) {
        self.targetProfileId = targetProfileId
        self.targetSpaceId = targetSpaceId
        self.targetWindowId = targetWindowId
        self.localDataStoreProvider = localDataStoreProvider
        self.analytics = BrowserImportAnalytics(capture: analyticsCapture)
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
        let sourceOptions = options
        let startedAtUptime = ProcessInfo.processInfo.systemUptime
        analytics.captureSelections(
            sources: sourceOptions,
            dataTypesPerBrowser: dataTypesPerBrowser
        )
        analytics.captureStarted(sources: sourceOptions)

        // Prefer the caller-provided window so Chromium import state follows the initiating window/profile.
        guard let windowId = targetWindowId ?? MainBrowserWindowControllersManager.shared.getFirstAvailableWindowId() else {
            AppLogError("No available window for import")
            failedImports = sourceOptions
            updateCompletionStatus()
            analytics.captureFinished(
                sources: sourceOptions,
                failedSources: failedImports,
                duration: ProcessInfo.processInfo.systemUptime - startedAtUptime,
                errorCode: .noWindow
            )
            isImporting = false
            ImportTargetLock.shared.end(into: lockedSpaceId)
            return true
        }

        AppLogInfo("Import started: browsers=\(options.map { Self.browserName(for: $0) }), "
            + "profileId=\(targetProfileId), spaceId=\(targetSpaceId)")

        // Validate the file source before any destructive work: if its path is
        // missing/unreadable (the file was moved or deleted after picking, or a nil
        // path reached us from a programmatic caller), drop `.file` so we neither
        // clear the Chromium bookmark staging below nor start an import that can't
        // succeed. Surface it as a failed import so the skip isn't silent.
        var options = options
        var runErrorCode: BrowserImportAnalytics.ErrorCode?
        if options.contains(.file) {
            let readable = importFilePath.map {
                !$0.isEmpty && FileManager.default.isReadableFile(atPath: $0)
            } ?? false
            if !readable {
                AppLogWarn("File import skipped: no readable file at \(importFilePath ?? "nil")")
                options.removeAll { $0 == .file }
                failedImports.append(.file)
                runErrorCode = .fileUnreadable
            }
        }

        // Only clear bookmarks if at least one browser is importing bookmarks
        let bookmarkSources = options.filter { option in
            guard let types = dataTypesPerBrowser?[option] else { return true } // nil = import all
            return types.contains(ImportDataType.bookmarks.rawValue)
        }
        let chromiumBookmarkSources = bookmarkSources.filter { $0 != .arc }
        if !chromiumBookmarkSources.isEmpty {
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
                let result = await importData(option, target: .window(windowId),
                    sourceProfileDirectory: sourceProfileDirectory, dataTypes: bridgeDataTypes,
                    importFilePath: importFilePath)
                switch result {
                case .completed(let success):
                    if !success {
                        failedImports.append(option)
                        if runErrorCode == nil {
                            runErrorCode = .sourceImportFailed
                        }
                    }
                    AppLogInfo("Import from \(option) completed with success: \(success)")
                case .bridgeUnavailable:
                    failedImports.append(option)
                    if runErrorCode == nil {
                        runErrorCode = .bridgeUnavailable
                    }
                }
            } else if option == .arc, !arcDataImportable, !(bridgeDataTypes?.isEmpty ?? true) {
                // Deliberate, safe skip: the chosen Space's profile is unresolved
                // (.unknown), so we import its bookmarks only and never fall back to
                // Default's data. Surface it so the skip isn't silent.
                AppLogWarn("Arc data import skipped for unresolved source profile; imported bookmarks only")
                failedImports.append(.arc)
                if runErrorCode == nil {
                    runErrorCode = .sourceImportFailed
                }
            }
        }

        let arcWantsBookmarks = dataTypesPerBrowser?[.arc]?.contains(ImportDataType.bookmarks.rawValue) ?? true
        let arcSpaceRoot = Self.arcBookmarkRoot(options: options, arcSpace: arcSpace, wantsBookmarks: arcWantsBookmarks)

        updateCompletionStatus()

        if !bookmarkSources.isEmpty || arcSpaceRoot != nil {
            Task {
                let persistence = await self.persistImportedBookmarksAfterSnapshot(
                    windowId: windowId,
                    arcSpaceRoot: arcSpaceRoot,
                    requiresChromiumSnapshot: !chromiumBookmarkSources.isEmpty
                )
                await MainActor.run {
                    if !persistence.snapshotSucceeded {
                        self.failedImports.append(
                            contentsOf: chromiumBookmarkSources
                        )
                    }
                    if !persistence.storeSucceeded {
                        self.failedImports.append(contentsOf: bookmarkSources)
                    }
                    self.failedImports = Self.uniqueBrowserTypes(
                        self.failedImports
                    )
                    self.updateCompletionStatus()
                    self.analytics.captureFinished(
                        sources: sourceOptions,
                        failedSources: self.failedImports,
                        duration: ProcessInfo.processInfo.systemUptime - startedAtUptime,
                        errorCode: persistence.succeeded
                            ? runErrorCode
                            : runErrorCode ?? .bookmarkPersistenceFailed
                    )
                    if self.failedImports.isEmpty {
                        FirstTimeActionTracker.capture(.importFinished)
                    }
                    self.isImporting = false
                }
                ImportTargetLock.shared.end(into: lockedSpaceId)
            }
        } else {
            analytics.captureFinished(
                sources: sourceOptions,
                failedSources: failedImports,
                duration: ProcessInfo.processInfo.systemUptime - startedAtUptime,
                errorCode: runErrorCode
            )
            if failedImports.isEmpty {
                FirstTimeActionTracker.capture(.importFinished)
            }
            isImporting = false
            ImportTargetLock.shared.end(into: lockedSpaceId)
        }

        return true
    }
    
    
    private func getArcSidebarData() -> Data? {
        return try? Data(contentsOf: Self.arcSidebarURL)
    }

    static let arcSidebarURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Arc/StorableSidebar.json")
    /// Arc's `Local State`; its profile cache reads through `loadChromiumProfiles`.
    static let arcLocalStateURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Arc/User Data/Local State")

    /// Returns all Arc Spaces from StorableSidebar.json, in Arc's sidebar order.
    /// Used by the import picker to let the user choose which Space to import.
    func loadArcSpaces() -> [ArcSpace] {
        guard let data = getArcSidebarData() else { return [] }
        return (try? ArcDataParserTool.parse(data: data))?.spaces ?? []
    }

    /// The Arc install as a Migration Source: its profiles from Arc's profile
    /// cache, plus everything the sidebar file yields.
    struct ArcMigrationSource {
        let profiles: [ChromiumProfileInfo]
        let sidebar: ArcSidebar

        /// The source-agnostic model the Migration planner consumes: a
        /// straight translation, so that every mapping decision — an
        /// unreadable profile record, a profile the cache never listed —
        /// stays in the planner.
        var migrationSource: BrowserMigrationSource {
            BrowserMigrationSource(
                profiles: profiles.map {
                    BrowserMigrationSourceProfile(key: $0.directory, displayName: $0.name)
                },
                defaultProfileKey: ArcSourceProfile.default.directoryName ?? "Default",
                spaces: sidebar.spaces.map {
                    BrowserMigrationSourceSpace(
                        id: $0.id,
                        name: $0.title,
                        colorHex: $0.colorHex,
                        profileKey: $0.profile.directoryName,
                        bookmarkRoot: $0.root)
                },
                pinnedGroups: sidebar.favorites.map { favorites in
                    BrowserMigrationSourcePinnedGroup(
                        profileKey: favorites.profile.directoryName,
                        entries: favorites.entries.map {
                            BrowserMigrationPinnedEntry(title: $0.title, url: $0.url)
                        })
                })
        }
    }

    /// Reads the Arc install as a Migration Source; nil when the sidebar file
    /// is missing or unreadable.
    func loadArcMigrationSource(
        sidebarURL: URL = arcSidebarURL,
        localStateURL: URL = arcLocalStateURL
    ) -> ArcMigrationSource? {
        guard let data = try? Data(contentsOf: sidebarURL),
              let sidebar = try? ArcDataParserTool.parse(data: data) else { return nil }
        return ArcMigrationSource(
            profiles: loadChromiumProfiles(localStateURL: localStateURL), sidebar: sidebar)
    }
    
    /// Imports data for one browser using a continuation-backed async flow.
    private enum SourceImportResult {
        case completed(Bool)
        case bridgeUnavailable
    }

    /// Which Chromium-side importer a request is routed to: the one behind an
    /// open window (the import window's path) or the one belonging to a Profile
    /// named by its on-disk basename (Migration's path, which has no window on
    /// the Profiles it has just created).
    private enum ImportTarget {
        case window(Int)
        case profile(String)
    }

    /// Starts one source → Profile import against a Profile named by its on-disk
    /// basename, without needing a window on it, and waits for the Chromium-side
    /// completion. Returns false when the import failed or was refused — an
    /// unknown Profile included, which fails through the same completion signal.
    ///
    /// This is the Migration entry point and deliberately carries none of the
    /// import window's run state: it does not take the reentrancy gate, the
    /// import target lock or the bookmark staging, because Migration owns those
    /// around its own units. Bookmarks are not part of it either — Migration
    /// writes each Space's bookmark tree itself.
    ///
    /// The destination is the parameter, never this importer's own
    /// `targetProfileId`: that property belongs to the import window's
    /// window/Profile/Space binding, which Migration does not use.
    ///
    /// Chromium reports completion keyed by browser type alone, so callers must
    /// not have two imports from the same source in flight — a second one
    /// overwrites the first continuation and strands it. Within one importer
    /// Migration's serial run is what prevents that; across two importers the
    /// completion is a NotificationCenter broadcast that both would consume, and
    /// only making Migration and the import window mutually exclusive fixes it.
    @MainActor
    func importDataIntoProfile(
        _ option: BrowserType,
        destinationProfileId: String,
        sourceProfileDirectory: String?,
        dataTypes: [String]?
    ) async -> Bool {
        // The profile-addressed selector arrives with the matching Phi Framework;
        // an older one would answer it with an unrecognised selector, so refuse
        // here the way the other new bridge calls do.
        guard let bridge = ChromiumLauncher.sharedInstance().bridge,
              bridge.responds(to: #selector(PhiChromiumBridgeProtocol
                  .importBrowserData(from:profile:dataTypes:targetProfileId:)))
        else {
            AppLogError(
                "Import into profile \(destinationProfileId) was not dispatched: "
                    + "the Chromium bridge does not support profile-addressed imports"
            )
            return false
        }

        let result = await importData(
            option,
            target: .profile(destinationProfileId),
            sourceProfileDirectory: sourceProfileDirectory,
            dataTypes: dataTypes
        )
        switch result {
        case .completed(let success): return success
        case .bridgeUnavailable: return false
        }
    }

    @MainActor
    private func importData(
        _ option: BrowserType,
        target: ImportTarget,
        sourceProfileDirectory: String?,
        dataTypes: [String]?,
        importFilePath: String? = nil
    ) async -> SourceImportResult {
        guard let bridge = ChromiumLauncher.sharedInstance().bridge else {
            AppLogError(
                "Import from \(Self.browserName(for: option)) was not "
                    + "dispatched: no Chromium bridge"
            )
            return .bridgeUnavailable
        }

        return await withCheckedContinuation { continuation in
            continuationQueue.async { [weak self] in
                guard let self = self else {
                    continuation.resume(returning: .completed(false))
                    return
                }

                self.importContinuations[option] = continuation

                DispatchQueue.main.async {
                    let profile = sourceProfileDirectory ?? ""
                    switch target {
                    case .window(let windowId):
                        if option == .file {
                            // File import: Chromium sniffs the file type + parses it, staging
                            // the result into its BookmarkModel to be pulled back like the
                            // browser sources. Completion arrives via importCompleted(.file).
                            bridge.importData(
                                fromFilePath: importFilePath ?? "",
                                windowId: Int64(windowId)
                            )
                        } else {
                            bridge.importBrowserData(
                                from: option,
                                profile: profile,
                                dataTypes: dataTypes,
                                windowId: Int64(windowId)
                            )
                        }
                    case .profile(let destinationProfileId):
                        // `.file` has no profile-addressed form; Chromium answers it
                        // with a failed completion, which resolves the continuation.
                        bridge.importBrowserData(
                            from: option,
                            profile: profile,
                            dataTypes: dataTypes,
                            targetProfileId: destinationProfileId
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
            
            continuation.resume(returning: .completed(success))
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
            let failedBrowserNames = failedImports.map { Self.browserName(for: $0) }.joined(separator: ", ")
            let format = NSLocalizedString("oobe.importBrowserData.progress.completedWithErrors", value: "Import completed with errors. Failed to import from: %@", comment: "Browser data importer - Status message when some imports failed, shows list of failed browsers")
            status = String(format: format, failedBrowserNames)
        }
    }
    
    /// Returns the user-facing browser name.
    private static func browserName(for type: BrowserType) -> String {
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

    private struct BookmarkPersistenceResult {
        let snapshotSucceeded: Bool
        let storeSucceeded: Bool

        var succeeded: Bool {
            snapshotSucceeded && storeSucceeded
        }
    }

    private func persistImportedBookmarksAfterSnapshot(
        windowId: Int,
        arcSpaceRoot: ArcDataParserTool.Bookmark?,
        requiresChromiumSnapshot: Bool
    ) async -> BookmarkPersistenceResult {
        try? await Task.sleep(nanoseconds: 3 * 1_000_000_000)

        let bookmarkWrappers: [BookmarkWrapper]
        let snapshotSucceeded: Bool
        if requiresChromiumSnapshot {
            let snapshot = await MainActor.run {
                ChromiumLauncher.sharedInstance().bridge?.getAllBookmarks(
                    withWindowId: windowId.int64Value
                )
            }
            if let snapshot {
                bookmarkWrappers = snapshot
                snapshotSucceeded = true
            } else {
                AppLogError("Imported bookmarks were dropped: no Chromium bridge is available")
                bookmarkWrappers = []
                snapshotSucceeded = false
            }
        } else {
            bookmarkWrappers = []
            snapshotSucceeded = true
        }

        let storeSucceeded = await persistImportedBookmarks(
            bookmarkWrappers,
            arcSpaceRoot: arcSpaceRoot
        )
        return BookmarkPersistenceResult(
            snapshotSucceeded: snapshotSucceeded,
            storeSucceeded: storeSucceeded
        )
    }

    /// Writes an imported tree into the local data store. Split out of the
    /// snapshot step so it can be driven without the Chromium bridge.
    @discardableResult
    func persistImportedBookmarks(
        _ bookmarks: [BookmarkWrapper],
        arcSpaceRoot: ArcDataParserTool.Bookmark?
    ) async -> Bool {
        guard let store = localDataStoreProvider() else {
            AppLogError("Imported bookmarks were dropped: no local data store is available")
            return false
        }

        await store.saveChromiumBookmarksToLocalStore(
            bookmarks, profileId: targetProfileId, spaceId: targetSpaceId)

        if let arcSpaceRoot {
            await store.saveArcBookmarksToLocalStore(
                arcSpaceRoot, profileId: targetProfileId, spaceId: targetSpaceId)
        }

        await store.reorderImportedBrowserFolders(
            profileId: targetProfileId, spaceId: targetSpaceId)
        return true
    }

    private static func uniqueBrowserTypes(
        _ browserTypes: [BrowserType]
    ) -> [BrowserType] {
        var seen = Set<String>()
        return browserTypes.filter {
            seen.insert(BrowserImportAnalytics.sourceName($0)).inserted
        }
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
            // An empty display name falls back to the directory basename.
            let name = (info["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? directory
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

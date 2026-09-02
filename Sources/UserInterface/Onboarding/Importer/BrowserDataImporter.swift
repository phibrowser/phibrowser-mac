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
        case .zen:
            return "zen"
        case .dia:
            return "dia"
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
        case importingDiaData
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
    /// Resolves the Chromium bridge every import request goes through, so a
    /// test can drive the importer without one.
    private let bridgeProvider: () -> PhiChromiumBridgeProtocol?
    private let analytics: BrowserImportAnalytics

    init(targetProfileId: String = LocalStore.defaultProfileId,
         targetSpaceId: String = SpaceManager.shared.currentDefaultSpaceId,
         targetWindowId: Int? = nil,
         localDataStoreProvider: @escaping () -> LocalStore? = {
             AccountController.shared.localDataAccount?.localStorage
         },
         bridgeProvider: @escaping () -> PhiChromiumBridgeProtocol? = {
             ChromiumLauncher.sharedInstance().bridge
         },
         analyticsCapture: @escaping BrowserImportAnalytics.Capture = {
             event, properties in
             PostHogSDK.shared.capture(event, properties: properties)
         }) {
        self.targetProfileId = targetProfileId
        self.targetSpaceId = targetSpaceId
        self.targetWindowId = targetWindowId
        self.localDataStoreProvider = localDataStoreProvider
        self.bridgeProvider = bridgeProvider
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
        diaProfileDirectory: String? = nil,
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
        let lockedProfileId = targetProfileId
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
            bridgeProvider()?.removeAllBookmarks(withWindowId: windowId.int64Value)
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
            case .dia:    sourceProfileDirectory = diaProfileDirectory
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
                    // The tree is in and the completion is announced: hand
                    // the Bookmarks still without an icon in the Space it
                    // landed in — the locked target, whatever the importer
                    // is retargeted to once `isImporting` clears — to the
                    // favicon backfill and move on. Never awaited; the
                    // status, the analytics and the lock below are as they
                    // were.
                    self.backfillFavicons(profileId: lockedProfileId, spaceId: lockedSpaceId)
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
    /// Arc's Chromium data folder; its presence is what "Arc is installed"
    /// means to the Migration wizard.
    static let arcUserDataURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Arc/User Data")
    /// Arc's `Local State`; its profile cache reads through `loadChromiumProfiles`.
    static let arcLocalStateURL = arcUserDataURL.appendingPathComponent("Local State")

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
                        icon: $0.icon.map(Self.sourceIcon),
                        profileKey: $0.profile.directoryName,
                        bookmarkRoot: $0.root)
                },
                pinnedGroups: sidebar.favorites.map { favorites in
                    BrowserMigrationSourcePinnedGroup(
                        profileKey: favorites.profile.directoryName,
                        entries: favorites.entries.map {
                            BrowserMigrationPinnedEntry(
                                title: $0.title, url: $0.url,
                                split: $0.split.map {
                                    BrowserMigrationPinnedSplit(
                                        secondaryTitle: $0.secondaryTitle,
                                        secondaryURL: $0.secondaryURL,
                                        layout: $0.layout)
                                })
                        })
                })
        }

        /// The parser's icon in the source model's vocabulary — a straight
        /// translation, like the rest of this adapter.
        private static func sourceIcon(_ icon: ArcSpaceIcon) -> BrowserMigrationSourceIcon {
            switch icon {
            case .emoji(let text): return .emoji(text)
            case .named(let name): return .arcNamed(name)
            }
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
    
    // MARK: - Dia

    /// Dia's Chromium data folder, in the standard layout; its presence is
    /// what "Dia is installed" means to the import window.
    static let diaUserDataURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Dia/User Data")
    /// Dia's `Local State`; its profile cache reads through `loadChromiumProfiles`.
    static let diaLocalStateURL = diaUserDataURL.appendingPathComponent("Local State")

    // MARK: - Zen

    /// Zen's application-support directory; `profiles.ini` in it is what
    /// "Zen is installed" means to the Migration wizard.
    static let zenApplicationSupportURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/zen")
    static let zenProfilesINIURL = zenApplicationSupportURL.appendingPathComponent("profiles.ini")
    /// Where Zen keeps its profile directories; a source profile's key is its
    /// basename here, which the Chromium-side Zen import resolves the same way.
    static let zenProfilesURL = zenApplicationSupportURL
        .appendingPathComponent(ZenDataParserTool.profilesDirectoryName)
    /// Zen's own store of its spaces and pinned tabs, in each profile
    /// directory — not Firefox's window session beside it.
    static let zenSessionFileName = "zen-sessions.jsonlz4"

    /// Zen's containers, in each profile directory: what a Space is set to.
    static let zenContainersFileName = "containers.json"

    /// The Zen install as a Migration Source: the Firefox profiles
    /// `profiles.ini` lists, and for each one that has them its session file
    /// and its containers.
    struct ZenMigrationSource {
        let profilesINI: ZenDataParserTool.ProfilesINI
        /// By Firefox profile key. A profile with no session file — never
        /// launched — has no entry here, and so no Spaces.
        let sessions: [String: ZenDataParserTool.Session]
        /// By Firefox profile key; a profile with no `containers.json` has
        /// none.
        let containers: [String: [ZenDataParserTool.Container]]

        /// What the no-container Profile of an install's sole usable Firefox
        /// profile is called. Firefox names a default profile after its
        /// release channel ("Default (release)"), which means nothing to the
        /// user. A product name, so not localized.
        static let soleProfileDisplayName = "Zen"

        /// A Zen Profile's key: the Firefox profile's directory basename and
        /// the id of the container, 0 for the Spaces set to none.
        static func profileKey(_ firefoxProfileKey: String, container userContextId: Int) -> String {
            "\(firefoxProfileKey)#\(userContextId)"
        }

        /// The source-agnostic model the Migration planner consumes.
        /// Containers are Profiles (ADR 0005): per usable Firefox profile —
        /// one whose session file yields a Space; the others are not listed
        /// at all, a Firefox profile being nothing the user chose in Zen —
        /// one Profile for the Spaces set to no container when there are
        /// any, then one per container: the ones Spaces are set to by first
        /// appearance in the session file, then the rest in the container
        /// list's own order, which the planner greys as having no Spaces
        /// (ADR 0005: an unused container still shows, so the user can see
        /// what Phi looked at). Every Profile derived from a
        /// Firefox profile reads its data from that profile's directory. A
        /// Space set to a container the list does not hold has no resolvable
        /// profile record: it binds to the install default's no-container
        /// Profile — the first usable profile's when the default is not
        /// usable — which is listed for it when nothing else would. Names
        /// are decided here, as the Migration Source interface leaves them to
        /// the source: a container Profile takes its container's name; the
        /// no-container Profile is "Zen" when exactly one Firefox profile is
        /// usable, and the `profiles.ini` name — empty → the directory
        /// basename — otherwise.
        ///
        /// The sidebar fills the model's two remaining parts. Each Space
        /// carries its workspace's own pins as its bookmark tree
        /// (`bookmarkRoot(of:in:)`). The Essentials are the pinned entries
        /// of the Profile of the container each carries (ADR 0005), in file
        /// order; those in a container no Space is set to go to its greyed
        /// row, where the planner creates nothing and counts them for the
        /// report — which is why the no-container Profile is listed, greyed
        /// and after the containers in use, for Essentials in no container
        /// even when no Space is set to none. An Essential in a container
        /// the list does not hold has no resolvable profile record and, like
        /// a Space set to one, follows the default Profile.
        var migrationSource: BrowserMigrationSource {
            let usableKeys = profilesINI.profiles.map(\.key)
                .filter { !(sessions[$0]?.spaces.isEmpty ?? true) }
            let soleUsableKey = usableKeys.count == 1 ? usableKeys[0] : nil
            let containersByID: [String: [Int: ZenDataParserTool.Container]] = Dictionary(
                usableKeys.map { key in
                    (key, Dictionary(
                        (containers[key] ?? []).map { ($0.userContextId, $0) },
                        uniquingKeysWith: { first, _ in first }))
                },
                uniquingKeysWith: { first, _ in first })
            // Set to a container the list does not hold — deleted since, or
            // never listed.
            func isMissingContainer(_ userContextId: Int, in key: String) -> Bool {
                userContextId != ZenDataParserTool.noContainerID
                    && containersByID[key]?[userContextId] == nil
            }
            let bindingHostKey = usableKeys.first { $0 == profilesINI.defaultProfileKey }
                ?? usableKeys.first
            // What binds to the host's no-container Profile from anywhere in
            // the install: a Space set to a missing container gives it a
            // Space, an Essential in one gives it a pinned entry.
            let hostsASpace = usableKeys.contains { key in
                (sessions[key]?.spaces ?? []).contains { isMissingContainer($0.containerTabId, in: key) }
            }
            let hostsAnEssential = usableKeys.contains { key in
                (sessions[key]?.pinnedTabs ?? []).contains {
                    $0.isEssential && isMissingContainer($0.userContextId, in: key)
                }
            }

            var profiles: [BrowserMigrationSourceProfile] = []
            var spaces: [BrowserMigrationSourceSpace] = []
            var pinnedGroups: [BrowserMigrationSourcePinnedGroup] = []
            for profile in profilesINI.profiles where usableKeys.contains(profile.key) {
                guard let session = sessions[profile.key] else { continue }
                let profileSpaces = session.spaces
                let known = containersByID[profile.key] ?? [:]
                let isHost = profile.key == bindingHostKey
                // Essentials by the container they carry, in file order; one
                // in a missing container has no resolvable profile record.
                var essentials: [Int: [BrowserMigrationPinnedEntry]] = [:]
                var unresolvedEssentials: [BrowserMigrationPinnedEntry] = []
                for tab in session.pinnedTabs where tab.isEssential {
                    let entry = BrowserMigrationPinnedEntry(title: tab.title, url: tab.url)
                    if isMissingContainer(tab.userContextId, in: profile.key) {
                        unresolvedEssentials.append(entry)
                    } else {
                        essentials[tab.userContextId, default: []].append(entry)
                    }
                }
                func listProfile(container userContextId: Int, displayName: String) {
                    let key = Self.profileKey(profile.key, container: userContextId)
                    profiles.append(BrowserMigrationSourceProfile(
                        key: key, displayName: displayName, sourceDirectory: profile.key))
                    if let entries = essentials[userContextId] {
                        pinnedGroups.append(
                            BrowserMigrationSourcePinnedGroup(profileKey: key, entries: entries))
                    }
                }
                let noContainerName = profile.key == soleUsableKey
                    ? Self.soleProfileDisplayName
                    : BrowserMigrationPlanner.resolvedDisplayName(of: profile.name, key: profile.key)
                // The no-container Profile leads when it has Spaces. When it
                // has only pinned entries — Essentials in no container, and
                // no Space set to none — it is listed greyed after the
                // containers in use, so those Essentials are counted rather
                // than lost.
                let noContainerHasSpaces = profileSpaces.contains { $0.containerTabId == ZenDataParserTool.noContainerID }
                    || (isHost && hostsASpace)
                let noContainerHasPins = essentials[ZenDataParserTool.noContainerID] != nil
                    || (isHost && hostsAnEssential)
                if noContainerHasSpaces {
                    listProfile(container: ZenDataParserTool.noContainerID, displayName: noContainerName)
                }
                var listed = Set<Int>()
                for container in profileSpaces.compactMap({ known[$0.containerTabId] })
                where listed.insert(container.userContextId).inserted {
                    listProfile(container: container.userContextId, displayName: Self.displayName(of: container))
                }
                if !noContainerHasSpaces, noContainerHasPins {
                    listProfile(container: ZenDataParserTool.noContainerID, displayName: noContainerName)
                }
                for container in containers[profile.key] ?? []
                where listed.insert(container.userContextId).inserted {
                    listProfile(container: container.userContextId, displayName: Self.displayName(of: container))
                }
                if !unresolvedEssentials.isEmpty {
                    pinnedGroups.append(BrowserMigrationSourcePinnedGroup(
                        profileKey: nil, entries: unresolvedEssentials))
                }
                for space in profileSpaces {
                    spaces.append(BrowserMigrationSourceSpace(
                        id: space.id,
                        name: space.name,
                        colorHex: space.colorHex,
                        icon: Self.sourceIcon(space.icon),
                        profileKey: isMissingContainer(space.containerTabId, in: profile.key)
                            ? nil : Self.profileKey(profile.key, container: space.containerTabId),
                        bookmarkRoot: Self.bookmarkRoot(of: space, in: session)))
                }
            }
            return BrowserMigrationSource(
                profiles: profiles,
                defaultProfileKey: bindingHostKey.map { Self.profileKey($0, container: 0) } ?? "",
                spaces: spaces,
                pinnedGroups: pinnedGroups)
        }

        /// A container Profile's name: Firefox's own English names for its
        /// four defaults, keyed off their `l10nId` and deliberately not
        /// localized — they are the containers' names, not Phi's copy; a
        /// custom container's name as typed; a number for an identity with
        /// neither.
        static func displayName(of container: ZenDataParserTool.Container) -> String {
            switch container.l10nId {
            case "user-context-personal": return "Personal"
            case "user-context-work": return "Work"
            case "user-context-banking": return "Banking"
            case "user-context-shopping": return "Shopping"
            default:
                if let name = container.name,
                   !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return name
                }
                return String(
                    format: NSLocalizedString("app.browserMigration.zen.container.numbered", value: "Container %d",
                        comment: "Browser migration wizard - name of the Profile made from a Zen container that has no readable name; %d is the container's number"),
                    container.userContextId)
            }
        }

        /// The Zen adapter the icon resolver's Zen table was written for: a
        /// built-in icon arrives as its
        /// `chrome://…/zen-icons/selectable/<name>.svg` URL and is named by
        /// that basename; any other non-empty string is the emoji text as
        /// typed.
        static func sourceIcon(_ icon: String?) -> BrowserMigrationSourceIcon? {
            guard let icon, !icon.isEmpty else { return nil }
            guard icon.hasPrefix("chrome://") else { return .emoji(icon) }
            let file = (icon as NSString).lastPathComponent as NSString
            return .zenNamed(file.deletingPathExtension)
        }

        /// A workspace's own pins as the Space's bookmark tree: the session
        /// file's workspace pins — not its Essentials, which belong to a
        /// container — that name this space, in file order and whatever
        /// container they carry, with their folders nested as `folders[]`
        /// nests them. A folder sits where its first pin appears, which is
        /// where Zen shows it (a folder is a Firefox tab group, and a
        /// group's tabs sit together), so a folder with nothing in it is
        /// never written. A pin in a folder the file does not list sits at
        /// the root; a chain of folders that loops — a shape Zen never
        /// writes — is cut where it comes back round, and the pin still
        /// sits inside its folders. A split view of two of the pins — a tab
        /// group of its own, whose pins carry its id as a folder's do — is
        /// one entry carrying both pages (`split`), the first pane's on the
        /// row, where the first of its pins appears: inside the folder the
        /// split is placed in, or at the root, never in a folder of its
        /// own. A split of any other shape — three or four panes, a pane
        /// that is not one of this Space's pins, no layout at all — falls
        /// back to its pins, plain, in place. The tree is the one type every
        /// Mac-side sidebar parser produces and the store's landing call
        /// takes, and it already carries a split.
        static func bookmarkRoot(
            of space: ZenDataParserTool.Space,
            in session: ZenDataParserTool.Session
        ) -> ArcDataParserTool.Bookmark {
            let root = ArcDataParserTool.Bookmark(
                guid: space.id, title: space.name, url: nil, isFolder: true)
            let folders = Dictionary(
                session.folders.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let splitViews = Dictionary(
                session.splitViews.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            var nodes: [String: ArcDataParserTool.Bookmark] = [:]
            func node(forFolder id: String, above: Set<String> = []) -> ArcDataParserTool.Bookmark {
                if let node = nodes[id] { return node }
                guard let folder = folders[id], !above.contains(id) else { return root }
                let parent = folder.parentID.map { node(forFolder: $0, above: above.union([id])) } ?? root
                let node = ArcDataParserTool.Bookmark(
                    guid: folder.id, title: folder.name, url: nil, isFolder: true)
                parent.children.append(node)
                nodes[id] = node
                return node
            }
            let pins = session.pinnedTabs.filter { !$0.isEssential && $0.workspaceID == space.id }
            /// The two pins a split shows, the first pane's first — when its
            /// top level is exactly two leaves and its pins are exactly the
            /// two they name; nil for any other shape.
            func pair(of split: ZenDataParserTool.SplitView)
                -> (primary: ZenDataParserTool.PinnedTab, secondary: ZenDataParserTool.PinnedTab)? {
                let members = pins.filter { $0.groupID == split.id }
                guard let paneTabIDs = split.paneTabIDs, paneTabIDs.count == 2, members.count == 2,
                      let primary = members.first(where: { $0.syncID == paneTabIDs[0] }),
                      let secondary = members.first(where: { $0.syncID == paneTabIDs[1] }),
                      primary != secondary else { return nil }
                return (primary, secondary)
            }
            func entry(for pin: ZenDataParserTool.PinnedTab) -> ArcDataParserTool.Bookmark {
                ArcDataParserTool.Bookmark(
                    guid: UUID().uuidString, title: pin.title, url: pin.url, isFolder: false)
            }
            var pairedSplits = Set<String>()
            for pin in pins {
                guard let split = pin.groupID.flatMap({ splitViews[$0] }) else {
                    let parent = pin.groupID.map { node(forFolder: $0) } ?? root
                    parent.children.append(entry(for: pin))
                    continue
                }
                // A split view is not a folder: what it shows sits in the
                // folder the split is placed in, or at the root.
                let parent = split.parentFolderID.map { node(forFolder: $0) } ?? root
                guard let pages = pair(of: split) else {
                    parent.children.append(entry(for: pin))
                    continue
                }
                // The pair lands once, where the first of its pins appears.
                guard pairedSplits.insert(split.id).inserted else { continue }
                let leaf = entry(for: pages.primary)
                leaf.split = ArcSplit(
                    secondaryTitle: pages.secondary.title,
                    secondaryURL: pages.secondary.url,
                    layout: splitLayout(fromZenDirection: split.direction))
                parent.children.append(leaf)
            }
            return root
        }

        /// Zen's `direction` names the axis the panes run along; Phi's
        /// `SplitLayout` names the divider between them. So Zen's `row`
        /// (panes side by side) is Phi's `vertical` bar and `column`
        /// (stacked) its `horizontal`; anything else is left to Phi's
        /// default.
        private static func splitLayout(fromZenDirection direction: String?) -> String? {
            switch direction {
            case "row": return SplitLayout.vertical.rawValue
            case "column": return SplitLayout.horizontal.rawValue
            default: return nil
            }
        }
    }

    /// Reads the Zen install as a Migration Source. Nil when `profiles.ini`
    /// cannot be read, or a profile's session or containers file is there but
    /// malformed — either puts the source in the wizard's "could not read"
    /// state. A profile with no session file is a never-launched one and
    /// simply has no Spaces; one with no containers file has no containers.
    func loadZenMigrationSource(
        profilesINIURL: URL = zenProfilesINIURL
    ) -> ZenMigrationSource? {
        guard let text = try? String(contentsOf: profilesINIURL, encoding: .utf8) else {
            AppLogError("Unable to read Zen profiles.ini at \(profilesINIURL.path)")
            return nil
        }
        let ini = ZenDataParserTool.parseProfilesINI(text)
        let profilesDirectory = profilesINIURL.deletingLastPathComponent()
            .appendingPathComponent(ZenDataParserTool.profilesDirectoryName)
        var sessions: [String: ZenDataParserTool.Session] = [:]
        var containers: [String: [ZenDataParserTool.Container]] = [:]
        for profile in ini.profiles {
            let directory = profilesDirectory.appendingPathComponent(profile.key)
            let sessionURL = directory.appendingPathComponent(Self.zenSessionFileName)
            let containersURL = directory.appendingPathComponent(Self.zenContainersFileName)
            do {
                if FileManager.default.fileExists(atPath: sessionURL.path) {
                    sessions[profile.key] = try ZenDataParserTool.parseSession(
                        container: Data(contentsOf: sessionURL))
                }
                if FileManager.default.fileExists(atPath: containersURL.path) {
                    containers[profile.key] = try ZenDataParserTool.parseContainers(
                        json: Data(contentsOf: containersURL))
                }
            } catch {
                AppLogError("Unable to read Zen profile \(directory.path): \(error)")
                return nil
            }
            if let session = sessions[profile.key], !session.spaces.isEmpty {
                Self.logZenPinsNamingNoSpace(in: session, profile: profile.key)
            }
        }
        return ZenMigrationSource(profilesINI: ini, sessions: sessions, containers: containers)
    }

    /// The workspace pins of a usable Zen profile that name a space the file
    /// does not list: no Space's tree takes them and nothing re-homes them,
    /// so the file read says so, once. (The builder's trees take exactly the
    /// pins naming a listed space; this is the complement.)
    private static func logZenPinsNamingNoSpace(in session: ZenDataParserTool.Session, profile: String) {
        let spaceIDs = Set(session.spaces.map(\.id))
        for pin in session.pinnedTabs where !pin.isEssential && !spaceIDs.contains(pin.workspaceID ?? "") {
            AppLogWarn("[BrowserMigration] dropping Zen pin \(pin.url) in \(profile): "
                + "workspace \(pin.workspaceID ?? "none") is not listed")
        }
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
        guard let bridge = bridgeProvider(),
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
        guard let bridge = bridgeProvider() else {
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
        case .dia:
            phase = .importingDiaData
            status = NSLocalizedString("oobe.importBrowserData.progress.importingDia", value: "Importing Dia data...", comment: "Browser data importer - Status message while importing Dia browser data")
        case .zen:
            // Zen is never offered by the import window: Migration drives it
            // through `importDataIntoProfile`, which reports no phase.
            phase = .waiting
            status = ""
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
        case .zen:
            return "Zen"
        case .dia:
            return "Dia"
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
                self.bridgeProvider()?.getAllBookmarks(
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

    /// Hands the Space's Bookmarks that hold no icon to the favicon backfill,
    /// in sidebar order: the rows the import just wrote, and any the Space
    /// already had without one. Leaving out the rows with an icon here is a
    /// pre-filter — an import lands in a Space the user already has, and
    /// the backfill reads every queued row back one by one — not a
    /// decision: which rows are asked, and what is written, the backfill
    /// still settles at each row's turn.
    @MainActor
    private func backfillFavicons(profileId: String, spaceId: String) {
        guard let store = localDataStoreProvider() else { return }
        let guids = FaviconBackfill.bookmarkGUIDs(
            under: store.fetchBookmarks(parentId: nil, profileId: profileId, spaceId: spaceId),
            where: { $0.favicon == nil })
        FaviconBackfill.shared.enqueue(profileId: profileId, guids: guids)
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

    /// Chrome Web Store `location` value in `Secure Preferences`.
    private static let webStoreExtensionLocation = 1

    /// How many Web Store extensions a source profile carries, read from the
    /// same file and by the same rule the Chromium-side extension importer
    /// applies: `from_webstore` set and `location` 1, in
    /// `<user data>/<profile>/Secure Preferences`. Zero when the file is
    /// missing or unreadable, which is what that importer finds there too.
    ///
    /// Counted on this side because extension installation is fire-and-forget
    /// over there: it tallies its own successes and failures and never sends
    /// them back. This is the number installation was *triggered* for, and the
    /// only one a report can honestly name.
    static func webStoreExtensionCount(
        userDataURL: URL, sourceProfileDirectory: String
    ) -> Int {
        let url = userDataURL
            .appendingPathComponent(sourceProfileDirectory)
            .appendingPathComponent("Secure Preferences")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let settings = (root["extensions"] as? [String: Any])?["settings"]
                  as? [String: Any]
        else {
            return 0
        }
        return settings.values.filter { entry in
            guard let entry = entry as? [String: Any] else { return false }
            return entry["from_webstore"] as? Bool == true
                && entry["location"] as? Int == webStoreExtensionLocation
        }.count
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

    /// Holds `spaceId` for the duration of `body` and releases it on every exit
    /// path — an early return and a thrown error included. There is no timeout
    /// behind this lock, so a caller that writes into a Space across several
    /// steps pairs the two structurally rather than by remembering to call
    /// `end`. Not re-entrant: the set carries no depth, so a nested hold of the
    /// same Space would release it at the inner exit.
    func holding(_ spaceId: String, _ body: () async throws -> Void) async rethrows {
        begin(into: spaceId)
        defer { end(into: spaceId) }
        try await body()
    }
}

// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import Combine
import SwiftData
class BrowserDataImporter {
    enum Phase {
        case waiting
        case importingChromeData
        case importingSafariData
        case importingArcData
        case done
    }

    struct ChromeProfileInfo: Equatable {
        let directory: String
        let name: String
        let email: String?
    }

    let targetProfileId: String
    let targetWindowId: Int?
    
    // Continuations for active import requests, keyed by browser type.
    private var importContinuations: [BrowserType: CheckedContinuation<Bool, Never>] = [:]
    private let continuationQueue = DispatchQueue(label: "com.phibrowser.import.continuation")
    
    private(set) var failedImports: [BrowserType] = []
    @Published private(set) var phase: Phase = .waiting
    @Published var status: String = ""
    
    init(targetProfileId: String = LocalStore.defaultProfileId, targetWindowId: Int? = nil) {
        self.targetProfileId = targetProfileId
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
    
    /// Starts importing data from the selected browsers.
    @MainActor
    func startImportData(_ options: [BrowserType], chromeProfileDirectory: String? = nil, dataTypesPerBrowser: [BrowserType: [String]]? = nil) async {
        // Prefer the caller-provided window so Chromium import state follows the initiating window/profile.
        guard let windowId = targetWindowId ?? MainBrowserWindowControllersManager.shared.getFirstAvailableWindowId() else {
            AppLogError("No available window for import")
            return
        }
        
        failedImports.removeAll()

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

            if option != .arc || !(bridgeDataTypes?.isEmpty ?? true) {
                let success = await importData(
                    option,
                    windowId: windowId,
                    chromeProfileDirectory: chromeProfileDirectory,
                    dataTypes: bridgeDataTypes
                )

                if !success {
                    failedImports.append(option)
                }

                AppLogInfo("Import from \(option) completed with success: \(success)")
            }
        }

        // Arc bookmarks: parse locally if user selected bookmarks for Arc
        let arcBookmarks: [ArcDataParserTool.Bookmark]
        let arcWantsBookmarks = dataTypesPerBrowser?[.arc]?.contains(ImportDataType.bookmarks.rawValue) ?? true
        if options.contains(.arc), arcWantsBookmarks, let arcData = getArcSidebarData() {
            do {
                arcBookmarks = try ArcDataParserTool.parse(data: arcData)
            } catch {
                AppLogError("\(error.localizedDescription)")
                arcBookmarks = []
            }
        } else {
            arcBookmarks = []
        }

        updateCompletionStatus()

        if importingBookmarks || !arcBookmarks.isEmpty {
            Task { [weak self] in
                guard let self else { return }
                await self.persistImportedBookmarksAfterSnapshot(
                    windowId: windowId,
                    arcBookmarks: arcBookmarks
                )
            }
        }
    }
    
    
    private func getArcSidebarData() -> Data? {
         let localStateURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Arc/StorableSidebar.json")
        return try? Data(contentsOf: localStateURL)
    }
    
    /// Imports data for one browser using a continuation-backed async flow.
    private func importData(
        _ option: BrowserType,
        windowId: Int,
        chromeProfileDirectory: String?,
        dataTypes: [String]?
    ) async -> Bool {
        return await withCheckedContinuation { continuation in
            continuationQueue.async { [weak self] in
                guard let self = self else {
                    continuation.resume(returning: false)
                    return
                }

                self.importContinuations[option] = continuation

                DispatchQueue.main.async {
                    let profile = (option == .chrome ? chromeProfileDirectory : nil) ?? ""
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
            status = NSLocalizedString("Importing Arc data...", comment: "Browser data importer - Status message while importing Arc browser data")
        case .chrome:
            phase = .importingChromeData
            status = NSLocalizedString("Importing Chrome data...", comment: "Browser data importer - Status message while importing Chrome browser data")
        case .safari:
            phase = .importingSafariData
            status = NSLocalizedString("Importing Safari data...", comment: "Browser data importer - Status message while importing Safari browser data")
        @unknown default:
            phase = .waiting
            status = ""
        }
    }
    
    private func updateCompletionStatus() {
        phase = .done
        if failedImports.isEmpty {
            status = NSLocalizedString("Import completed successfully", comment: "Browser data importer - Status message when all imports completed successfully")
        } else {
            let failedBrowserNames = failedImports.map { browserName(for: $0) }.joined(separator: ", ")
            let format = NSLocalizedString("Import completed with errors. Failed to import from: %@", comment: "Browser data importer - Status message when some imports failed, shows list of failed browsers")
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
        @unknown default:
            return "Unknown"
        }
    }

    private func persistImportedBookmarksAfterSnapshot(
        windowId: Int,
        arcBookmarks: [ArcDataParserTool.Bookmark]
    ) async {
        try? await Task.sleep(nanoseconds: 3 * 1_000_000_000)

        let bookmarkWrappers = await MainActor.run {
            ChromiumLauncher
                .sharedInstance()
                .bridge?
                .getAllBookmarks(withWindowId: windowId.int64Value)
        }

        await AccountController.shared.account?
            .localStorage
            .saveChromiumBookmarksToLocalStore(
                bookmarkWrappers ?? [],
                profileId: targetProfileId
            )

        if !arcBookmarks.isEmpty {
            await AccountController.shared.account?.localStorage.saveArcBookmarksToLocalStore(
                arcBookmarks,
                profileId: targetProfileId
            )
        }

        await AccountController.shared.account?.localStorage.reorderImportedBrowserFolders(
            profileId: targetProfileId
        )
    }

    func loadChromeProfiles() -> [ChromeProfileInfo] {
        let localStateURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Google/Chrome/Local State")
        guard let data = try? Data(contentsOf: localStateURL) else {
            AppLogError("Unable to read Chrome Local State at \(localStateURL.path)")
            return []
        }
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let profile = root["profile"] as? [String: Any],
            let infoCache = profile["info_cache"] as? [String: Any],
            let profilesOrder = profile["profiles_order"] as? [String]
        else {
            AppLogError("Invalid Chrome Local State profile structure")
            return []
        }

        var results: [ChromeProfileInfo] = []
        results.reserveCapacity(profilesOrder.count)
        for directory in profilesOrder {
            guard let info = infoCache[directory] as? [String: Any] else {
                continue
            }
            let name = (info["name"] as? String) ?? directory
            let email = info["user_name"] as? String
            results.append(ChromeProfileInfo(directory: directory, name: name, email: email))
        }

        return results
    }
}

// MARK: - Notification Name
extension Notification.Name {
    static let browserImportCompleted = Notification.Name("browserImportCompleted")
}

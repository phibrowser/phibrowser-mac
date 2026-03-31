// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import Combine

/// Download item state enumeration matching Chromium's DownloadItem::DownloadState
enum DownloadState: Int {
    case inProgress = 0
    case complete = 1
    case cancelled = 2
    case interrupted = 3
    
    var displayName: String {
        switch self {
        case .inProgress: return NSLocalizedString("Downloading", comment: "Download state")
        case .complete: return NSLocalizedString("Completed", comment: "Download state")
        case .cancelled: return NSLocalizedString("Cancelled", comment: "Download state")
        case .interrupted: return NSLocalizedString("Failed", comment: "Download state")
        }
    }
}

/// Swift model for download item
class DownloadItem: ObservableObject, Identifiable {
    let id: String  // guid
    
    @Published var fileName: String
    @Published var url: String
    @Published var mimeType: String
    @Published var state: DownloadState
    @Published var totalBytes: Int64
    @Published var receivedBytes: Int64
    @Published var percentComplete: Int
    @Published var currentSpeed: Int64
    @Published var startTime: Date?
    @Published var endTime: Date?
    @Published var canShowInFolder: Bool
    @Published var canOpenDownload: Bool
    @Published var canResume: Bool
    @Published var isPaused: Bool
    @Published var isDone: Bool
    @Published var isDangerous: Bool
    @Published var dangerType: Int
    @Published var isInsecure: Bool
    @Published var insecureDownloadStatus: Int
    @Published var targetFilePath: String

    // MARK: - Safety State (delegates to DownloadSafetyComputation)

    var safetyState: DownloadSafetyState {
        DownloadSafetyComputation.computeSafetyState(
            isDangerous: isDangerous,
            dangerType: dangerType,
            isInsecure: isInsecure,
            insecureDownloadStatus: insecureDownloadStatus,
            downloadState: state.rawValue
        )
    }

    var safetyWarningText: String? {
        guard let key = DownloadSafetyComputation.warningTextKey(
            safetyState: safetyState,
            dangerType: dangerType,
            isInsecure: isInsecure,
            insecureDownloadStatus: insecureDownloadStatus
        ) else { return nil }
        return NSLocalizedString(key, tableName: "DownloadSafety", comment: "Download safety warning text")
    }

    var shortSafetyWarningText: String? {
        guard let key = DownloadSafetyComputation.shortWarningTextKey(
            safetyState: safetyState,
            dangerType: dangerType,
            isInsecure: isInsecure,
            insecureDownloadStatus: insecureDownloadStatus
        ) else { return nil }
        return NSLocalizedString(key, tableName: "DownloadSafety", comment: "Download safety short status text")
    }

    var sourceHost: String {
        guard let urlObj = URL(string: url) else { return url }
        return urlObj.host ?? url
    }
    
    /// Display name shown in UI, falling back to the URL path when needed.
    var displayFileName: String {
        if !fileName.isEmpty {
            return fileName
        }
        if let urlObj = URL(string: url) {
            let lastComponent = urlObj.lastPathComponent
            if !lastComponent.isEmpty && lastComponent != "/" {
                return lastComponent
            }
        }
        return NSLocalizedString("Downloading...", comment: "Placeholder text when download filename is not yet available")
    }
    
    var formattedProgress: String {
        let oneGB = 1_000_000_000.0
        let oneMB = 1_000_000.0

        if totalBytes > 0 {
            let received = Double(receivedBytes)
            let total = Double(totalBytes)

            if total >= oneGB {
                let receivedGB = received / oneGB
                let totalGB = total / oneGB
                return String(format: "%.2f / %.2f GB", receivedGB, totalGB)
            } else {
                let receivedMB = received / oneMB
                let totalMB = total / oneMB
                return String(format: "%.1f / %.1f MB", receivedMB, totalMB)
            }
        } else if receivedBytes > 0 {
            let received = Double(receivedBytes)

            if received >= oneGB {
                let receivedGB = received / oneGB
                return String(format: "%.2f GB", receivedGB)
            } else {
                let receivedMB = received / oneMB
                return String(format: "%.1f MB", receivedMB)
            }
        }

        return ""
    }
    
    var formattedSpeed: String {
        guard currentSpeed > 0 else { return "" }
        let speedKB = Double(currentSpeed) / 1000.0
        if speedKB > 1000 {
            return String(format: "%.1f MB/s", speedKB / 1000.0)
        }
        return String(format: "%.0f KB/s", speedKB)
    }
    
    init(from wrapper: DownloadItemWrapper) {
        self.id = wrapper.guid
        self.fileName = wrapper.fileNameToReportUser
        self.url = wrapper.url
        self.mimeType = wrapper.mimeType
        self.state = DownloadState(rawValue: wrapper.state) ?? .inProgress
        self.totalBytes = wrapper.totalBytes
        self.receivedBytes = wrapper.receivedBytes
        self.percentComplete = wrapper.percentComplete
        self.currentSpeed = wrapper.currentSpeed
        self.startTime = wrapper.startTime > 0 ? Date(timeIntervalSince1970: TimeInterval(wrapper.startTime) / 1000.0) : nil
        self.endTime = wrapper.endTime > 0 ? Date(timeIntervalSince1970: TimeInterval(wrapper.endTime) / 1000.0) : nil
        self.canShowInFolder = wrapper.canShowInFolder && !wrapper.fileExternallyRemoved
        self.canOpenDownload = wrapper.canOpenDownload
        self.canResume = wrapper.canResume
        self.isPaused = wrapper.isPaused
        self.isDone = wrapper.isDone
        self.isDangerous = wrapper.isDangerous
        self.dangerType = Int(wrapper.dangerType)
        self.isInsecure = wrapper.isInsecure
        self.insecureDownloadStatus = Int(wrapper.insecureDownloadStatus)
        self.targetFilePath = wrapper.targetFilePath
    }

    func update(from wrapper: DownloadItemWrapper) {
        self.fileName = wrapper.fileNameToReportUser
        self.state = DownloadState(rawValue: wrapper.state) ?? .inProgress
        self.totalBytes = wrapper.totalBytes
        self.receivedBytes = wrapper.receivedBytes
        self.percentComplete = wrapper.percentComplete
        self.currentSpeed = wrapper.currentSpeed
        self.endTime = wrapper.endTime > 0 ? Date(timeIntervalSince1970: TimeInterval(wrapper.endTime) / 1000.0) : nil
        self.canShowInFolder = wrapper.canShowInFolder
        self.canOpenDownload = wrapper.canOpenDownload
        self.canResume = wrapper.canResume
        self.isPaused = wrapper.isPaused
        self.isDone = wrapper.isDone
        self.isDangerous = wrapper.isDangerous
        self.dangerType = Int(wrapper.dangerType)
        self.isInsecure = wrapper.isInsecure
        self.insecureDownloadStatus = Int(wrapper.insecureDownloadStatus)
        self.targetFilePath = wrapper.targetFilePath
    }

    #if DEBUG
    /// Mock initializer for preview and testing
    init(id: String, fileName: String, url: String, state: DownloadState = .complete, 
         percentComplete: Int = 100, totalBytes: Int64 = 0, receivedBytes: Int64 = 0) {
        self.id = id
        self.fileName = fileName
        self.url = url
        self.mimeType = ""
        self.state = state
        self.totalBytes = totalBytes
        self.receivedBytes = receivedBytes
        self.percentComplete = percentComplete
        self.currentSpeed = 0
        self.startTime = Date()
        self.endTime = state == .complete ? Date() : nil
        self.canShowInFolder = state == .complete
        self.canOpenDownload = state == .complete
        self.canResume = state == .interrupted
        self.isPaused = false
        self.isDone = state == .complete
        self.isDangerous = false
        self.dangerType = 0
        self.isInsecure = false
        self.insecureDownloadStatus = 0
        self.targetFilePath = "/Downloads/\(fileName)"
    }
    #endif
}

extension DownloadItem {
    /// Maximum age for a download to be considered "new" in the floating list.
    static let maxCreationAge: TimeInterval = 5.0
    var isNewlyCreate: Bool {
        return Date().timeIntervalSince(startTime ?? Date.distantPast) <= Self.maxCreationAge
    }
}

/// Download event for publishing to observers
struct DownloadEvent {
    let eventType: DownloadEventType
    let downloadItem: DownloadItem?
}

class DownloadsManager: ObservableObject {
    weak var browserState: BrowserState?
    
    @Published var downloads: [DownloadItem] = []
    
    /// Aggregate progress across all in-progress downloads.
    @Published var totalDownloadProgress: Double = 0.0
    
    /// Publisher consumed by living-download UI and other observers.
    let downloadEventPublisher = PassthroughSubject<DownloadEvent, Never>()
    
    /// Number of currently active downloads.
    var activeDownloadCount: Int {
        downloads.filter { $0.state == .inProgress }.count
    }
    
    /// Whether there are any active downloads.
    var hasActiveDownloads: Bool {
        activeDownloadCount > 0
    }
    
    private var windowId: Int64 {
        Int64(browserState?.windowId ?? 0)
    }
    
    init(browserState: BrowserState? = nil) {
        self.browserState = browserState
    }

    private func updateTotalProgress() {
        let inProgressItems = downloads.filter { $0.state == .inProgress }
        
        guard !inProgressItems.isEmpty else {
            totalDownloadProgress = 0.0
            return
        }
        
        var totalReceived: Int64 = 0
        var totalSize: Int64 = 0
        var unknownSizeCount = 0
        var unknownSizePercentSum = 0
        
        for item in inProgressItems {
            if item.totalBytes > 0 {
                // Known size: use actual bytes
                totalReceived += item.receivedBytes
                totalSize += item.totalBytes
            } else if item.percentComplete >= 0 {
                // Unknown size but has percent: track separately
                unknownSizeCount += 1
                unknownSizePercentSum += item.percentComplete
            }
            // If neither totalBytes nor percentComplete is available, ignore this item
        }
        
        // Calculate progress
        var progress: Double = 0.0
        
        if totalSize > 0 {
            // Weight by byte count for known-size downloads
            let knownSizeProgress = Double(totalReceived) / Double(totalSize)
            
            if unknownSizeCount > 0 {
                // Mix known-size and unknown-size progress
                let unknownSizeProgress = Double(unknownSizePercentSum) / Double(unknownSizeCount * 100)
                let knownWeight = Double(inProgressItems.count - unknownSizeCount) / Double(inProgressItems.count)
                let unknownWeight = Double(unknownSizeCount) / Double(inProgressItems.count)
                progress = knownSizeProgress * knownWeight + unknownSizeProgress * unknownWeight
            } else {
                progress = knownSizeProgress
            }
        } else if unknownSizeCount > 0 {
            // All downloads have unknown size
            progress = Double(unknownSizePercentSum) / Double(unknownSizeCount * 100)
        }
        
        totalDownloadProgress = min(1.0, max(0.0, progress))
    }
    
    /// Refresh download list from Chromium
    func refreshDownloads() {
        guard let bridge = ChromiumLauncher.sharedInstance().bridge else {
            AppLogWarn("📥 [Downloads] Bridge not available")
            return
        }
        
        let wrappers = bridge.getAllDownloadItems(withWindowId: windowId)
        
        var newDownloads: [DownloadItem] = []
        for wrapper in wrappers {
            if let existing = downloads.first(where: { $0.id == wrapper.guid }) {
                existing.update(from: wrapper)
                newDownloads.append(existing)
            } else {
                newDownloads.append(DownloadItem(from: wrapper))
            }
        }
        
        // Sort: in-progress first, then by start time (newest first) within each group
        newDownloads.sort { item1, item2 in
            let isInProgress1 = item1.state == .inProgress
            let isInProgress2 = item2.state == .inProgress
            
            // In-progress items come first
            if isInProgress1 != isInProgress2 {
                return isInProgress1
            }
            
            // Within same group, sort by start time (newest first)
            return (item1.startTime ?? .distantPast) > (item2.startTime ?? .distantPast)
        }
        
        downloads = newDownloads
        updateTotalProgress()
        AppLogDebug("📥 [Downloads] Refreshed \(downloads.count) items, progress: \(Int(totalDownloadProgress * 100))%")
        
        // Check if completed files still exist on disk
        checkCompletedFilesExistence()
    }
    
    /// Asynchronously check if completed download files still exist on disk
    private func checkCompletedFilesExistence() {
        // Get completed items that claim they can show in folder
        let itemsToCheck = downloads.filter { $0.state == .complete && $0.canShowInFolder }
        
        guard !itemsToCheck.isEmpty else { return }
        
        DispatchQueue.global(qos: .utility).async {
            for item in itemsToCheck {
                let filePath = item.targetFilePath
                guard !filePath.isEmpty else { continue }
                
                let fileExists = FileManager.default.fileExists(atPath: filePath)
                
                if !fileExists {
                    // Update property on main thread
                    DispatchQueue.main.async {
                        item.canShowInFolder = false
                        item.canOpenDownload = false
                    }
                }
            }
        }
    }
    
    /// Handle download event from Chromium
    func handleDownloadEvent(eventType: DownloadEventType, guid: String, wrapper: DownloadItemWrapper?) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            var affectedItem: DownloadItem?
            
            switch eventType {
            case .created:
                if let wrapper = wrapper {
                    let newItem = DownloadItem(from: wrapper)
                    self.downloads.insert(newItem, at: 0)
                    affectedItem = newItem
                }
                
            case .updated, .completed, .paused, .resumed:
                if let wrapper = wrapper,
                   let existing = self.downloads.first(where: { $0.id == guid }) {
                    existing.update(from: wrapper)
                    affectedItem = existing
                }
                
            case .cancelled, .interrupted:
                if let wrapper = wrapper,
                   let existing = self.downloads.first(where: { $0.id == guid }) {
                    existing.update(from: wrapper)
                    affectedItem = existing
                }
                
            case .removed, .destroyed:
                affectedItem = self.downloads.first { $0.id == guid }
                self.downloads.removeAll { $0.id == guid }
                
            case .opened:
                // No UI update needed
                break
                
            @unknown default:
                break
            }
            
            // Update total progress after any download event
            self.updateTotalProgress()
            
            // Publish event for observers (LivingDownloadsManager, etc.)
            let event = DownloadEvent(eventType: eventType, downloadItem: affectedItem)
            self.downloadEventPublisher.send(event)
        }
    }
    
    // MARK: - Download Actions
    
    func pauseDownload(_ item: DownloadItem) {
        ChromiumLauncher.sharedInstance().bridge?.pauseDownload(withGuid: item.id, windowId: windowId)
    }
    
    func resumeDownload(_ item: DownloadItem) {
        ChromiumLauncher.sharedInstance().bridge?.resumeDownload(withGuid: item.id, windowId: windowId)
    }
    
    func cancelDownload(_ item: DownloadItem) {
        ChromiumLauncher.sharedInstance().bridge?.cancelDownload(withGuid: item.id, windowId: windowId)
    }
    
    func removeDownload(_ item: DownloadItem) {
        ChromiumLauncher.sharedInstance().bridge?.removeDownload(withGuid: item.id, windowId: windowId)
    }
    
    func openDownload(_ item: DownloadItem) {
        ChromiumLauncher.sharedInstance().bridge?.openDownload(withGuid: item.id, windowId: windowId)
    }
    
    func showInFinder(_ item: DownloadItem) {
        ChromiumLauncher.sharedInstance().bridge?.showDownloadInFinder(withGuid: item.id, windowId: windowId)
    }
    
    // MARK: - Safety Actions

    func keepDownload(_ item: DownloadItem) {
        // Only warning state allows Keep; blocked/policyBlocked should only Discard
        guard item.safetyState == .warning else { return }

        if item.isInsecure {
            ChromiumLauncher.sharedInstance().bridge?.validateInsecureDownload(withGuid: item.id, windowId: windowId)
        } else if item.isDangerous {
            ChromiumLauncher.sharedInstance().bridge?.validateDangerousDownload(withGuid: item.id, windowId: windowId)
        }
    }

    func discardDownload(_ item: DownloadItem) {
        ChromiumLauncher.sharedInstance().bridge?.removeDownload(withGuid: item.id, windowId: windowId)
    }

    func copyLink(_ item: DownloadItem) {
        let link = item.url
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(link, forType: .string)
    }
}

extension BrowserState {
//    private(set) lazy var downloadsManager: DownloadsManager = { .init(browserState: self) }()
}

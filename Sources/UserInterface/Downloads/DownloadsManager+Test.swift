// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

// This file contains mock data and test utilities for testing the Downloads UI.
// Use TestDownloadsManager instead of DownloadsManager for preview and testing.

import Foundation
import Combine

#if DEBUG

// MARK: - Test Downloads Manager

/// A mock DownloadsManager for testing and previewing the Downloads UI
class TestDownloadsManager: DownloadsManager {
    private var progressTimers: [String: Timer] = [:]
    private var cancellables = Set<AnyCancellable>()
    
    override init(browserState: BrowserState? = nil) {
        super.init(browserState: nil)
        loadMockData()
    }
    
    deinit {
        stopAllTimers()
    }
    
    // MARK: - Mock Data
    
    func loadMockData() {
        downloads = [
            // 1. Completed download
            createMockItem(
                id: "completed-1",
                fileName: "Phi-Browser-1.0.0.dmg",
                url: "https://releases.phi.com/downloads/Phi-Browser-1.0.0.dmg",
                state: .complete,
                totalBytes: 156_000_000,
                receivedBytes: 156_000_000,
                percentComplete: 100
            ),
            
            // 2. Failed/Interrupted download
            createMockItem(
                id: "failed-1",
                fileName: "large-video-file.mp4",
                url: "https://videos.example.com/stream/large-video-file.mp4",
                state: .interrupted,
                totalBytes: 2_500_000_000,
                receivedBytes: 890_000_000,
                percentComplete: 35,
                canResume: true
            ),
            
            // 3. In-progress download (will animate)
            createMockItem(
                id: "progress-1",
                fileName: "xcode-15.2.0.xip",
                url: "https://developer.apple.com/downloads/xcode-15.2.0.xip",
                state: .inProgress,
                totalBytes: 8_000_000_000,
                receivedBytes: 2_400_000_000,
                percentComplete: 30,
                currentSpeed: 15_000_000  // 15 MB/s
            ),
            
            // 4. Paused download
            createMockItem(
                id: "paused-1",
                fileName: "archive-backup-2024.zip",
                url: "https://cloud.storage.com/backups/archive-backup-2024.zip",
                state: .inProgress,
                totalBytes: 4_000_000_000,
                receivedBytes: 1_200_000_000,
                percentComplete: 30,
                isPaused: true,
                canResume: true
            ),
            
            // 5. Another completed download
            createMockItem(
                id: "completed-2",
                fileName: "document-report-q4.pdf",
                url: "https://docs.company.com/reports/document-report-q4.pdf",
                state: .complete,
                totalBytes: 5_200_000,
                receivedBytes: 5_200_000,
                percentComplete: 100
            ),
            
            // 6. Cancelled download
            createMockItem(
                id: "cancelled-1",
                fileName: "old-installer.exe",
                url: "https://downloads.software.com/old-installer.exe",
                state: .cancelled,
                totalBytes: 250_000_000,
                receivedBytes: 50_000_000,
                percentComplete: 20
            )
        ]
        
        // Start progress animation for in-progress downloads
        startProgressAnimation(for: "progress-1")
    }
    
    private func createMockItem(
        id: String,
        fileName: String,
        url: String,
        state: DownloadState,
        totalBytes: Int64 = 0,
        receivedBytes: Int64 = 0,
        percentComplete: Int = 0,
        currentSpeed: Int64 = 0,
        isPaused: Bool = false,
        canResume: Bool = false
    ) -> DownloadItem {
        let item = DownloadItem(
            id: id,
            fileName: fileName,
            url: url,
            state: state,
            percentComplete: percentComplete,
            totalBytes: totalBytes,
            receivedBytes: receivedBytes
        )
        item.currentSpeed = currentSpeed
        item.isPaused = isPaused
        item.canResume = canResume || state == .interrupted
        item.canShowInFolder = state == .complete
        item.canOpenDownload = state == .complete
        item.isDone = state == .complete
        return item
    }
    
    // MARK: - Progress Animation
    
    func startProgressAnimation(for itemId: String) {
        guard let item = downloads.first(where: { $0.id == itemId }),
              item.state == .inProgress,
              !item.isPaused else {
            return
        }
        
        // Stop existing timer
        progressTimers[itemId]?.invalidate()
        
        // Create new timer that updates progress every 0.5 seconds
        let timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self, weak item] _ in
            guard let self = self, let item = item else { return }
            
            // Skip if paused or completed
            guard item.state == .inProgress && !item.isPaused else {
                self.progressTimers[itemId]?.invalidate()
                self.progressTimers.removeValue(forKey: itemId)
                return
            }
            
            // Simulate download progress
            let speedVariation = Int64.random(in: -2_000_000...2_000_000)
            let currentSpeed = max(5_000_000, item.currentSpeed + speedVariation) // At least 5 MB/s
            let bytesDownloaded = currentSpeed / 2  // Per 0.5 second
            
            let newReceived = min(item.totalBytes, item.receivedBytes + bytesDownloaded)
            let newPercent = item.totalBytes > 0 ? Int((Double(newReceived) / Double(item.totalBytes)) * 100) : 0
            
            DispatchQueue.main.async {
                item.receivedBytes = newReceived
                item.percentComplete = newPercent
                item.currentSpeed = currentSpeed
                
                // Complete the download when it reaches 100%
                if newPercent >= 100 {
                    item.state = .complete
                    item.isDone = true
                    item.canShowInFolder = true
                    item.canOpenDownload = true
                    item.currentSpeed = 0
                    self.progressTimers[itemId]?.invalidate()
                    self.progressTimers.removeValue(forKey: itemId)
                }
                
                // Trigger UI update
                self.objectWillChange.send()
            }
        }
        
        progressTimers[itemId] = timer
    }
    
    func stopProgressAnimation(for itemId: String) {
        progressTimers[itemId]?.invalidate()
        progressTimers.removeValue(forKey: itemId)
    }
    
    func stopAllTimers() {
        for timer in progressTimers.values {
            timer.invalidate()
        }
        progressTimers.removeAll()
    }
    
    // MARK: - Override Actions
    
    override func refreshDownloads() {
        // Do nothing for mock - data is already loaded
        AppLogDebug("📥 [TestDownloads] refreshDownloads called (mock)")
    }
    
    override func pauseDownload(_ item: DownloadItem) {
        AppLogDebug("📥 [TestDownloads] Pausing: \(item.fileName)")
        
        guard item.state == .inProgress else { return }
        
        stopProgressAnimation(for: item.id)
        
        DispatchQueue.main.async {
            item.isPaused = true
            item.canResume = true
            item.currentSpeed = 0
            self.objectWillChange.send()
        }
    }
    
    override func resumeDownload(_ item: DownloadItem) {
        AppLogDebug("📥 [TestDownloads] Resuming: \(item.fileName)")
        
        // Handle resume from paused state
        if item.state == .inProgress && item.isPaused {
            DispatchQueue.main.async {
                item.isPaused = false
                item.currentSpeed = Int64.random(in: 10_000_000...20_000_000)
                self.startProgressAnimation(for: item.id)
                self.objectWillChange.send()
            }
            return
        }
        
        // Handle retry from interrupted/cancelled state
        if item.state == .interrupted || item.state == .cancelled {
            DispatchQueue.main.async {
                item.state = .inProgress
                item.isPaused = false
                item.canResume = true
                item.currentSpeed = Int64.random(in: 10_000_000...20_000_000)
                self.startProgressAnimation(for: item.id)
                self.objectWillChange.send()
            }
        }
    }
    
    override func cancelDownload(_ item: DownloadItem) {
        AppLogDebug("📥 [TestDownloads] Cancelling: \(item.fileName)")
        
        stopProgressAnimation(for: item.id)
        
        DispatchQueue.main.async {
            item.state = .cancelled
            item.isPaused = false
            item.currentSpeed = 0
            item.canResume = false
            self.objectWillChange.send()
        }
    }
    
    override func removeDownload(_ item: DownloadItem) {
        AppLogDebug("📥 [TestDownloads] Removing: \(item.fileName)")
        
        stopProgressAnimation(for: item.id)
        
        DispatchQueue.main.async {
            self.downloads.removeAll { $0.id == item.id }
        }
    }
    
    override func openDownload(_ item: DownloadItem) {
        AppLogDebug("📥 [TestDownloads] Opening: \(item.fileName)")
        // In test mode, just log the action
    }
    
    override func showInFinder(_ item: DownloadItem) {
        AppLogDebug("📥 [TestDownloads] Showing in Finder: \(item.fileName)")
        // In test mode, just log the action
    }
    
    // MARK: - Test Helpers
    
    /// Add a new in-progress download for testing
    func addNewDownload(fileName: String = "new-download-\(UUID().uuidString.prefix(8)).zip", 
                        totalBytes: Int64 = 500_000_000) {
        let newItem = createMockItem(
            id: UUID().uuidString,
            fileName: fileName,
            url: "https://example.com/downloads/\(fileName)",
            state: .inProgress,
            totalBytes: totalBytes,
            receivedBytes: 0,
            percentComplete: 0,
            currentSpeed: Int64.random(in: 10_000_000...25_000_000)
        )
        
        DispatchQueue.main.async {
            self.downloads.insert(newItem, at: 0)
            self.startProgressAnimation(for: newItem.id)
        }
    }
    
    /// Simulate a download failure
    func simulateFailure(for itemId: String) {
        guard let item = downloads.first(where: { $0.id == itemId }) else { return }
        
        stopProgressAnimation(for: itemId)
        
        DispatchQueue.main.async {
            item.state = .interrupted
            item.isPaused = false
            item.currentSpeed = 0
            item.canResume = true
            self.objectWillChange.send()
        }
    }
    
    /// Simulate download completion
    func simulateCompletion(for itemId: String) {
        guard let item = downloads.first(where: { $0.id == itemId }) else { return }
        
        stopProgressAnimation(for: itemId)
        
        DispatchQueue.main.async {
            item.state = .complete
            item.receivedBytes = item.totalBytes
            item.percentComplete = 100
            item.currentSpeed = 0
            item.isDone = true
            item.canShowInFolder = true
            item.canOpenDownload = true
            self.objectWillChange.send()
        }
    }
}

// MARK: - SwiftUI Preview Extensions

import SwiftUI

struct DownloadsListView_TestPreview: PreviewProvider {
    static var previews: some View {
        Group {
            // Light mode
            DownloadsListView(downloadsManager: TestDownloadsManager())
                .frame(width: 340, height: 400)
                .background(Color(NSColor.windowBackgroundColor))
                .previewDisplayName("Downloads List - Light")
            
            // Dark mode
            DownloadsListView(downloadsManager: TestDownloadsManager())
                .frame(width: 340, height: 400)
                .background(Color(NSColor.windowBackgroundColor))
                .preferredColorScheme(.dark)
                .previewDisplayName("Downloads List - Dark")
            
            // Empty state
            DownloadsListView(downloadsManager: EmptyTestDownloadsManager())
                .frame(width: 340, height: 200)
                .background(Color(NSColor.windowBackgroundColor))
                .previewDisplayName("Downloads List - Empty")
        }
    }
}

/// Empty downloads manager for testing empty state
class EmptyTestDownloadsManager: DownloadsManager {
    override init(browserState: BrowserState? = nil) {
        super.init(browserState: nil)
        downloads = []
    }
    
    override func refreshDownloads() {
        // Keep empty
    }
}

// MARK: - Test View Controller

/// A test view for interactive testing of the Downloads UI
struct DownloadsTestView: View {
    @StateObject private var manager = TestDownloadsManager()
    
    var body: some View {
        VStack(spacing: 0) {
            // Test controls
            VStack(spacing: 8) {
                Text("Download Test Controls")
                    .font(.headline)
                    .padding(.top, 8)
                
                HStack(spacing: 8) {
                    Button("Add Download") {
                        manager.addNewDownload()
                    }
                    
                    Button("Fail First In-Progress") {
                        if let item = manager.downloads.first(where: { $0.state == .inProgress }) {
                            manager.simulateFailure(for: item.id)
                        }
                    }
                    
                    Button("Complete First In-Progress") {
                        if let item = manager.downloads.first(where: { $0.state == .inProgress }) {
                            manager.simulateCompletion(for: item.id)
                        }
                    }
                    
                    Button("Reset") {
                        manager.stopAllTimers()
                        manager.loadMockData()
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
            }
            .background(Color.gray.opacity(0.1))
            
            Divider()
            
            // Downloads list
            DownloadsListView(downloadsManager: manager)
        }
        .frame(width: 400, height: 500)
    }
}

struct DownloadsTestView_Previews: PreviewProvider {
    static var previews: some View {
        DownloadsTestView()
            .previewDisplayName("Interactive Test View")
    }
}

#endif

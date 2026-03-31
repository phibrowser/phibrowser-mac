// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

// A view model for managing overlay toasts displayed on top of the browser window.
// Designed to be extensible for various toast types (downloads, notifications, etc.)

import Cocoa
import Combine

class OverlayToastViewModel: ObservableObject {
    let browserState: BrowserState
    
    // MARK: - Toast Components
    
    /// Living downloads manager for download notification toasts.
    /// Automatically subscribes to DownloadsManager's events internally.
    @Published private(set) var livingDownloadsManager: LivingDownloadsManager
    
    /// Notification card manager for AI notification cards.
    let notificationCardManager: NotificationCardManager
    
    // MARK: - Visibility States
    
    /// Whether the living downloads toast should be visible
    @Published var isLivingDownloadsVisible: Bool = false
    
    /// Whether the notification card should be visible
    @Published var isNotificationCardVisible: Bool = false
    
    // MARK: - Hit Testing
    
    /// All hit-testable frames in the container's coordinate space (AppKit: origin bottom-left).
    /// Automatically collected from widgets marked with .overlayHitTestable() modifier.
    var hitTestFrames: [CGRect] = []
    
    private var cancellables = Set<AnyCancellable>()
    
    /// Delay used so removal animations can finish before the overlay hides.
    private let hideDelay: TimeInterval = 0.3
    
    init(browserState: BrowserState, notificationCardManager: NotificationCardManager = .shared) {
        self.browserState = browserState
        self.livingDownloadsManager = LivingDownloadsManager(downloadsManager: browserState.downloadsManager)
        self.notificationCardManager = notificationCardManager
        
        setupBindings()
    }
    
    private func setupBindings() {
        // Show immediately when items appear, hide after a short delay when the list empties.
        livingDownloadsManager.$livingItems
            .map { !$0.isEmpty }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] hasItems in
                guard let self = self else { return }
                
                if hasItems {
                    self.isLivingDownloadsVisible = true
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + self.hideDelay) { [weak self] in
                        guard let self = self else { return }
                        if self.livingDownloadsManager.livingItems.isEmpty {
                            self.isLivingDownloadsVisible = false
                        }
                    }
                }
            }
            .store(in: &cancellables)
        
        // Notification card visibility is coordinated by `NotificationCardManager`.
        notificationCardManager.shouldShowInLegacy
            .receive(on: DispatchQueue.main)
            .sink { [weak self] shouldShow in
                guard let self = self else { return }
                
                AppLogDebug("[CardDisplay] OverlayToastViewModel received shouldShowInLegacy=\(shouldShow)")
                
                if shouldShow {
                    AppLogDebug("[CardDisplay] Setting isNotificationCardVisible=true")
                    self.isNotificationCardVisible = true
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + self.hideDelay) { [weak self] in
                        guard let self = self else { return }
                        let shouldHide = self.notificationCardManager.activeDisplayMode != .legacy ||
                            self.notificationCardManager.latestCard == nil ||
                            self.notificationCardManager.isExplicitlyHidden
                        AppLogDebug("[CardDisplay] Delayed hide check: shouldHide=\(shouldHide), isExplicitlyHidden=\(self.notificationCardManager.isExplicitlyHidden)")
                        if shouldHide {
                            AppLogDebug("[CardDisplay] Setting isNotificationCardVisible=false")
                            self.isNotificationCardVisible = false
                        }
                    }
                }
            }
            .store(in: &cancellables)
    }
    
    // MARK: - Hit Testing
    
    /// Check if a point (in container's coordinate space) should be handled by any overlay widget.
    /// - Parameter point: The point in the container's coordinate space (origin at bottom-left for AppKit)
    /// - Returns: true if the point is inside any hit-testable area
    func shouldHandleHitTest(at point: CGPoint) -> Bool {
        return hitTestFrames.contains { $0.contains(point) }
    }
}

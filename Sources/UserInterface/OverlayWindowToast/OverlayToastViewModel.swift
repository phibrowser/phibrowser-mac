// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

// A view model for managing overlay toasts displayed on top of the browser window.
// Designed to be extensible for various toast types (downloads, notifications, etc.)

import Cocoa
import Combine
import SwiftUI

class OverlayToastViewModel: ObservableObject {
    /// The Space whose toasts are shown. A shell window's shared overlay
    /// follows the presented Space (`bind(to:)`).
    @Published private(set) var browserState: BrowserState
    let toastCenter: OverlayToastCenter
    let isPanel: Bool
    
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

    /// Generic window-scoped toasts owned by `OverlayToastCenter`.
    @Published private(set) var genericToasts: [OverlayToastItem] = []

    /// Current window layout mode used for layout-sensitive overlay positioning.
    @Published private(set) var layoutMode: LayoutMode

    /// The page area's insets inside the overlay. A shell window's overlay
    /// covers the whole window and lays its toasts out in the page area.
    @Published var contentInsets = EdgeInsets()
    
    // MARK: - Hit Testing
    
    /// All hit-testable frames in the container's coordinate space (AppKit: origin bottom-left).
    /// Automatically collected from widgets marked with .overlayHitTestable() modifier.
    var hitTestFrames: [CGRect] = []
    
    private var cancellables = Set<AnyCancellable>()
    private var stateCancellables = Set<AnyCancellable>()
    
    /// Delay used so removal animations can finish before the overlay hides.
    private let hideDelay: TimeInterval = 0.3
    
    init(
        browserState: BrowserState,
        notificationCardManager: NotificationCardManager = .shared,
        toastCenter: OverlayToastCenter = .shared,
        isPanel: Bool = false
    ) {
        self.browserState = browserState
        self.toastCenter = toastCenter
        self.isPanel = isPanel
        self.livingDownloadsManager = browserState.livingDownloadsManager
        self.notificationCardManager = notificationCardManager
        self.layoutMode = browserState.layoutMode
        
        bindStateSubscriptions()
        setupNotificationCardBinding()
    }

    /// Shows `state`'s toasts instead of the current Space's.
    func bind(to state: BrowserState) {
        guard state !== browserState else { return }
        browserState = state
        livingDownloadsManager = state.livingDownloadsManager
        layoutMode = state.layoutMode
        bindStateSubscriptions()
    }

    private func bindStateSubscriptions() {
        stateCancellables.removeAll()

        browserState.$layoutMode
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.layoutMode = $0 }
            .store(in: &stateCancellables)

        toastCenter.visibleToastsPublisher(for: browserState.windowId)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.genericToasts = $0 }
            .store(in: &stateCancellables)

        guard !isPanel else { return }

        isLivingDownloadsVisible = !livingDownloadsManager.livingItems.isEmpty
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
            .store(in: &stateCancellables)
    }

    private func setupNotificationCardBinding() {
        guard !isPanel else { return }

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

    func genericToasts(for placement: OverlayToastPlacement) -> [OverlayToastItem] {
        genericToasts.filter { $0.placement == placement }
    }

    var genericToastTopOffset: CGFloat {
        isPanel ? 16 : Self.genericToastTopOffset(for: layoutMode)
    }

    static func genericToastTopOffset(for layoutMode: LayoutMode) -> CGFloat {
        switch layoutMode {
        case .comfortable:
            return 88
        case .performance:
            return 16
        case .balanced:
            return 56
        }
    }
}

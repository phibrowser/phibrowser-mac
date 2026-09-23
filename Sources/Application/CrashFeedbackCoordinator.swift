// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit

/// Coordinates the application-wide invitation after a previous-session crash.
/// Created during didFinishLaunching, with crash delivery deferred to the main queue.
@MainActor
final class CrashFeedbackCoordinator {
    private var pendingCrash: PreviousSessionCrashContext?
    private var observers: [NSObjectProtocol] = []
    private var retryWorkItem: DispatchWorkItem?
    private var retryCount = 0
    private var isTerminationInProgress = false
    private static let lastPromptedEventIDKey = "feedback.lastPromptedCrashEventID"

    deinit {
        retryWorkItem?.cancel()
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    func enqueue(_ context: PreviousSessionCrashContext) {
        guard pendingCrash == nil,
              UserDefaults.standard.string(forKey: Self.lastPromptedEventIDKey) != context.eventID else { return }
        pendingCrash = context
        retryCount = 0
        let names: [Notification.Name] = [
            NSApplication.didBecomeActiveNotification,
            NSWindow.didBecomeKeyNotification,
            NSWindow.didEndSheetNotification,
            .mainAccountChanged,
            .browserAccessStateDidChange,
            .loginStatusRefreshCompleted,
            .activeBrowserWindowDidChange
        ]
        observers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                DispatchQueue.main.async {
                    self?.presentIfReady()
                }
            }
        }
        presentIfReady()
    }

    func suspendForTermination() {
        isTerminationInProgress = true
        retryWorkItem?.cancel()
        retryWorkItem = nil
    }

    func resumeAfterCancelledTermination() {
        isTerminationInProgress = false
        presentIfReady()
    }

    func stop() {
        isTerminationInProgress = true
        clearPendingRequest()
    }

    private func clearPendingRequest() {
        pendingCrash = nil
        retryWorkItem?.cancel()
        retryWorkItem = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
    }

    private func presentIfReady() {
        guard let context = pendingCrash,
              !isTerminationInProgress, NSApp.isActive,
              ApplicationState.shared.isAuthenticated,
              AccountController.shared.account != nil else { return }
        let manager = SpaceSessionControllersManager.shared
        let windows = manager.getAllWindows()
        let host = ([manager.activeWindowController].compactMap { $0 } + windows).first {
            $0.browserType == .normal && $0.window?.isVisible == true
        }
        guard let host else { return }
        guard !SpaceManager.shared.isSessionRestoreInFlight,
              !manager.isGuestTransitionInteractionBlocked,
              NSApp.modalWindow == nil,
              !NSApp.windows.contains(where: { $0.attachedSheet != nil }) else {
            // Restore visibility has no completion notification. Bound polling;
            // later activation/login/window events can still resume this request.
            guard retryWorkItem == nil, retryCount < 60 else { return }
            retryCount += 1
            let work = DispatchWorkItem { [weak self] in
                self?.retryWorkItem = nil
                self?.presentIfReady()
            }
            retryWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
            return
        }

        // Consume before showing: making the feedback window key emits notifications.
        clearPendingRequest()
        if host.showFeedbackWindow(previousSessionCrash: context) {
            // Dismissal counts as an answer; never ask again for this event.
            UserDefaults.standard.set(context.eventID, forKey: Self.lastPromptedEventIDKey)
        }
    }
}

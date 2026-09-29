// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import CocoaLumberjackSwift
import Foundation

/// Supervises Sentinel liveness while Phi AI is enabled and relaunches it when
/// it dies.
///
/// Hybrid monitoring (see `docs/sentinel-lifecycle.md`):
/// - Primary: `NSWorkspace` `didTerminateApplicationNotification`, filtered to
///   the Sentinel bundle ID, gives an immediate reaction with zero polling cost.
/// - Backstop: a low-frequency liveness poll in case a termination notification
///   is ever missed.
/// - Debounced recovery: on a death signal wait `debounceInterval` and re-check
///   before relaunching, so Sentinel's own self-relaunch (version guard) window
///   does not trigger a duplicate launch.
///
/// Relaunch policy: exponential backoff that never gives up (log-only, no UI).
/// A death occurring at least `stabilityWindow` after the last watchdog relaunch
/// resets the attempt counter and relaunches immediately.
///
/// `start()`/`stop()` are idempotent. `stop()` must be called *before* an
/// intentional Sentinel shutdown (`SentinelHelper.requestTerminationForBrowserUpdate()`)
/// so the watchdog does not resurrect a Sentinel we are deliberately shutting
/// down (Phi AI disable, browser OTA install).
@MainActor
final class SentinelWatchdog {
    static let shared = SentinelWatchdog()

    private let isRunningProvider: () -> Bool
    private let launcher: () -> Void
    private let workspaceNotificationCenter: NotificationCenter
    private let sentinelBundleIDProvider: () -> String
    private let now: () -> Date
    private let sleep: (TimeInterval) async -> Void
    private let logger: (String) -> Void

    private let debounceInterval: TimeInterval
    private let pollInterval: TimeInterval
    private let backoffCap: TimeInterval
    private let stabilityWindow: TimeInterval

    private(set) var isMonitoring = false
    private var observer: NSObjectProtocol?
    private(set) var pollTask: Task<Void, Never>?
    private(set) var recoveryTask: Task<Void, Never>?
    private(set) var attemptCount = 0
    private(set) var lastRelaunchAt: Date?

    init(
        isRunningProvider: @escaping () -> Bool = { SentinelHelper.isRunning },
        launcher: @escaping () -> Void = SentinelHelper.launch,
        workspaceNotificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        sentinelBundleIDProvider: @escaping () -> String = { SentinelHelper.loginItemIdentifier() },
        now: @escaping () -> Date = Date.init,
        sleep: @escaping (TimeInterval) async -> Void = { seconds in
            let nanoseconds = UInt64(max(0, seconds) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
        },
        logger: @escaping (String) -> Void = { AppLogInfo("[SentinelWatchdog] \($0)") },
        debounceInterval: TimeInterval = 2,
        pollInterval: TimeInterval = 60,
        backoffCap: TimeInterval = 300,
        stabilityWindow: TimeInterval = 600
    ) {
        self.isRunningProvider = isRunningProvider
        self.launcher = launcher
        self.workspaceNotificationCenter = workspaceNotificationCenter
        self.sentinelBundleIDProvider = sentinelBundleIDProvider
        self.now = now
        self.sleep = sleep
        self.logger = logger
        self.debounceInterval = debounceInterval
        self.pollInterval = pollInterval
        self.backoffCap = backoffCap
        self.stabilityWindow = stabilityWindow
    }

    // MARK: - Lifecycle

    /// Begins supervising Sentinel. Idempotent.
    func start() {
        guard !isMonitoring else { return }
        isMonitoring = true

        observer = workspaceNotificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            // Extract the (Sendable) bundle identifier synchronously on the
            // posting thread, then hop to the main actor to touch state.
            let bundleID = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
                .bundleIdentifier
            Task { @MainActor [weak self] in
                self?.handlePossibleSentinelTermination(bundleID: bundleID)
            }
        }

        startPollLoop()
        logger("started monitoring")
    }

    /// Stops supervising Sentinel and cancels any in-flight recovery. Idempotent.
    func stop() {
        guard isMonitoring else { return }
        isMonitoring = false

        if let observer {
            workspaceNotificationCenter.removeObserver(observer)
        }
        observer = nil

        pollTask?.cancel()
        pollTask = nil

        recoveryTask?.cancel()
        recoveryTask = nil

        logger("stopped monitoring")
    }

    // MARK: - Death detection

    /// Handles a candidate termination. `bundleID` is the terminated app's
    /// bundle identifier (from the workspace notification). Exposed so the thin
    /// notification observer stays testable without constructing a real
    /// `NSRunningApplication`.
    func handlePossibleSentinelTermination(bundleID: String?) {
        guard isMonitoring else { return }
        guard let bundleID else { return }
        guard bundleID.caseInsensitiveCompare(sentinelBundleIDProvider()) == .orderedSame else { return }
        triggerRecovery(reason: "termination notification")
    }

    /// Backstop liveness check body, run each poll tick. Exposed for testing so
    /// the poll path can be exercised without a real timer loop.
    func performPollCheck() {
        guard isMonitoring else { return }
        guard !isRunningProvider() else { return }
        triggerRecovery(reason: "poll backstop")
    }

    private func startPollLoop() {
        pollTask = Task { [weak self] in
            while self?.isMonitoring == true {
                let interval = self?.pollInterval ?? 0
                await self?.sleep(interval)
                self?.performPollCheck()
            }
        }
    }

    // MARK: - Recovery

    private func triggerRecovery(reason: String) {
        guard isMonitoring else { return }
        // Single-flight: overlapping death signals (notification + poll) collapse
        // into one recovery task.
        guard recoveryTask == nil else { return }

        logger("death signal (\(reason)); scheduling recovery")
        recoveryTask = Task { [weak self] in
            await self?.performRecovery()
            self?.recoveryTask = nil
        }
    }

    private func performRecovery() async {
        // 1. Debounce, then re-check: Sentinel's own self-relaunch has a brief
        //    old-exits/new-starts window that must not trigger a duplicate launch.
        await sleep(debounceInterval)
        guard isMonitoring else { return }
        if isRunningProvider() {
            logger("Sentinel recovered during debounce; no relaunch")
            return
        }

        // 2. Compute backoff delay. A death at least `stabilityWindow` after the
        //    last relaunch (or the first death ever) resets the attempt counter.
        if let lastRelaunchAt {
            if now().timeIntervalSince(lastRelaunchAt) >= stabilityWindow {
                attemptCount = 0
            }
        } else {
            attemptCount = 0
        }

        let delay: TimeInterval = attemptCount == 0
            ? 0
            : min(pow(2, Double(attemptCount - 1)), backoffCap)

        // 3. Wait out the backoff, then re-check before relaunching.
        if delay > 0 {
            await sleep(delay)
            guard isMonitoring else { return }
            if isRunningProvider() {
                logger("Sentinel recovered during backoff; no relaunch")
                return
            }
        }

        // 4. Relaunch.
        launcher()
        attemptCount += 1
        lastRelaunchAt = now()
        logger("relaunched Sentinel (attempt \(attemptCount), delay \(delay)s)")
    }
}

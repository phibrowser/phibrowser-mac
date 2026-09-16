// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import Foundation

enum PhiUninstallCoordinatorError: Error, LocalizedError {
    case unsupportedBundleIdentifier(String)
    case invalidAppSignature(URL)
    case accountCredentialCleanupFailed
    case sentinelDidNotExit

    var errorDescription: String? {
        switch self {
        case .unsupportedBundleIdentifier(let bundleIdentifier):
            return "The running Phi product is not supported for uninstall: \(bundleIdentifier)."
        case .invalidAppSignature(let url):
            return "The running Phi app failed signature verification at \(url.path)."
        case .accountCredentialCleanupFailed:
            return "Phi account credentials could not be removed."
        case .sentinelDidNotExit:
            return "Phi Sentinel did not exit before uninstall."
        }
    }
}

@MainActor
final class PhiUninstallCoordinator {
    enum State: Equatable {
        case idle
        case preparing
        case stoppingSentinel
        case committed
    }

    struct Environment {
        var presentConfirmation: @MainActor () -> Bool
        var makePlan: @MainActor () throws -> PhiUninstallPlan
        var prepareHelper: @MainActor (PhiUninstallPlan) throws -> PreparedPhiUninstaller
        var unregisterSentinel: @MainActor () async -> Void
        var stopSentinelWatchdog: @MainActor () -> Void
        var requestSentinelTermination: @MainActor () -> Bool
        var launchHelper: @MainActor (PreparedPhiUninstaller) throws -> RunningPhiUninstaller
        var clearLocalAccountData: @MainActor (_ postSharedTokenChange: Bool) -> Bool
        var clearBitwardenSession: @MainActor () async throws -> Void
        var resumeBitwardenSession: @MainActor () async -> Void
        var cleanupHelper: @MainActor (PreparedPhiUninstaller) -> Void
        var restoreSentinel: @MainActor () -> Void
        var presentFailure: @MainActor (Error) -> Void
        var quit: @MainActor () -> Void

        static var live: Environment {
            Environment(
                presentConfirmation: PhiUninstallCoordinator.presentConfirmationAlert,
                makePlan: PhiUninstallCoordinator.makeCurrentPlan,
                prepareHelper: { try PhiUninstallHelperLauncher.prepare(plan: $0) },
                unregisterSentinel: { await SentinelHelper.unregister() },
                stopSentinelWatchdog: { SentinelWatchdog.shared.stop() },
                requestSentinelTermination: {
                    SentinelHelper.requestTerminationForBrowserUpdate()
                },
                launchHelper: { try PhiUninstallHelperLauncher.launch($0) },
                clearLocalAccountData: {
                    AuthManager.shared.clearLocalAccountData(
                        postSharedTokenChange: $0
                    )
                },
                clearBitwardenSession: {
                    try await BitwardenService.shared.prepareForUninstall()
                },
                resumeBitwardenSession: {
                    await BitwardenService.shared.resumeAfterCancelledUninstall()
                },
                cleanupHelper: { PhiUninstallHelperLauncher.cleanup($0) },
                restoreSentinel: {
                    if PhiPreferences.AISettings.launchSentinelOnLogin.loadValue() {
                        SentinelHelper.register()
                    }
                    if PhiPreferences.AISettings.phiAIEnabled.loadValue() {
                        SentinelHelper.launch()
                        SentinelWatchdog.shared.start()
                    }
                },
                presentFailure: PhiUninstallCoordinator.presentFailureAlert,
                quit: { NSApp.terminate(nil) }
            )
        }
    }

    static let shared = PhiUninstallCoordinator()

    private(set) var state: State = .idle
    private let environment: Environment

    init(environment: Environment = .live) {
        self.environment = environment
    }

    func start() {
        guard state == .idle, environment.presentConfirmation() else { return }
        Task { @MainActor in
            await performConfirmedUninstall()
        }
    }

    func performConfirmedUninstall() async {
        guard state == .idle else { return }
        state = .preparing

        var preparedHelper: PreparedPhiUninstaller?
        var runningHelper: RunningPhiUninstaller?
        var sentinelShutdownStarted = false
        var bitwardenPrepared = false
        do {
            let plan = try environment.makePlan()
            let prepared = try environment.prepareHelper(plan)
            preparedHelper = prepared

            state = .stoppingSentinel
            sentinelShutdownStarted = true
            await environment.unregisterSentinel()
            environment.stopSentinelWatchdog()
            guard environment.requestSentinelTermination() else {
                throw PhiUninstallCoordinatorError.sentinelDidNotExit
            }

            let helper = try environment.launchHelper(prepared)
            runningHelper = helper
            guard environment.clearLocalAccountData(false) else {
                throw PhiUninstallCoordinatorError.accountCredentialCleanupFailed
            }
            try await environment.clearBitwardenSession()
            bitwardenPrepared = true
            try helper.commit()

            preparedHelper = nil
            runningHelper = nil
            state = .committed
            environment.quit()
        } catch {
            runningHelper?.cancel()
            if bitwardenPrepared {
                await environment.resumeBitwardenSession()
            }
            if let preparedHelper {
                environment.cleanupHelper(preparedHelper)
            }
            if sentinelShutdownStarted {
                environment.restoreSentinel()
            }
            state = .idle
            environment.presentFailure(error)
        }
    }

    private static func makeCurrentPlan() throws -> PhiUninstallPlan {
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? ""
        guard let channel = PhiUninstallChannel.from(browserBundleID: bundleIdentifier) else {
            throw PhiUninstallCoordinatorError.unsupportedBundleIdentifier(bundleIdentifier)
        }
        let appBundleURL = Bundle.main.bundleURL
        guard PhiUninstallSignatureVerifier.verifyAppBundle(
            at: appBundleURL,
            expectedBundleID: channel.browserBundleID
        ) else {
            throw PhiUninstallCoordinatorError.invalidAppSignature(appBundleURL)
        }
        let chatShimID = PhiChatUninstallIdentity.shimBundleIdentifier(
            browserBundleIdentifier: channel.browserBundleID
        )
        let chatShimURL = NSWorkspace.shared.runningApplications
            .first(where: { $0.bundleIdentifier == chatShimID })?.bundleURL
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: chatShimID)
        return PhiUninstallPlan(
            hostProcessID: ProcessInfo.processInfo.processIdentifier,
            channel: channel,
            appBundleURL: appBundleURL,
            chatShimBundleURL: chatShimURL
        )
    }

    private static func presentConfirmationAlert() -> Bool {
        makeConfirmationAlert().runModal() == .alertFirstButtonReturn
    }

    static func makeConfirmationAlert() -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = NSLocalizedString(
            "app.uninstall.confirmation.title",
            value: "Uninstall Phi?",
            comment: "Phi uninstall - Critical confirmation alert title before permanently removing the app and local data"
        )
        alert.informativeText = NSLocalizedString(
            "app.uninstall.confirmation.message",
            value: "Phi and Phi Sentinel will quit. Browsing data, conversations, AI memory, service data, and local AI models for this version of Phi will be permanently deleted. This cannot be undone.",
            comment: "Phi uninstall - Critical confirmation message describing the channel-scoped data that will be permanently removed"
        )
        let uninstallButton = alert.addButton(withTitle: NSLocalizedString(
            "app.uninstall.confirmation.uninstallButton",
            value: "Uninstall",
            comment: "Phi uninstall - Destructive confirmation button that starts uninstalling Phi"
        ))
        uninstallButton.hasDestructiveAction = true

        alert.addButton(withTitle: NSLocalizedString(
            "app.uninstall.confirmation.cancelButton",
            value: "Cancel",
            comment: "Phi uninstall - Button that cancels the uninstall confirmation"
        ))
        return alert
    }

    private static func presentFailureAlert(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = NSLocalizedString(
            "app.uninstall.failure.title",
            value: "Phi Could Not Be Uninstalled",
            comment: "Phi uninstall - Error alert title when the uninstall helper could not be prepared or launched"
        )
        alert.informativeText = String(
            format: NSLocalizedString(
                "app.uninstall.failure.message",
                value: "Phi and its local files were not removed. Some sign-in data may already have been cleared. %@",
                comment: "Phi uninstall - Error alert message after uninstall preparation fails; the placeholder is the technical reason and sign-in cleanup may have partially completed"
            ),
            error.localizedDescription
        )
        alert.addButton(withTitle: NSLocalizedString(
            "app.uninstall.failure.dismissButton",
            value: "OK",
            comment: "Phi uninstall - Button that dismisses an uninstall startup failure"
        ))
        alert.runModal()
    }
}

extension AppController {
    @MainActor
    @objc func uninstallPhi(_ sender: Any?) {
        PhiUninstallCoordinator.shared.start()
    }
}

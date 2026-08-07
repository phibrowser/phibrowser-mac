// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

#if !PHI_OSS_BUILD
import Cocoa
import Sparkle
import WebKit

@MainActor
final class PhiSparkleUserDriver: SPUStandardUserDriver {
    private final class UpdateChoiceContext {
        weak var driver: PhiSparkleUserDriver?
        weak var windowController: PhiSparkleUpdateWindowController?

        init(driver: PhiSparkleUserDriver, windowController: PhiSparkleUpdateWindowController) {
            self.driver = driver
            self.windowController = windowController
        }
    }

    weak var updater: SPUUpdater?
    var onUserInitiatedUpdateCheck: (() -> Void)?

    private var updateWindowController: PhiSparkleUpdateWindowController?

    init(hostBundle: Bundle = .main) {
        super.init(hostBundle: hostBundle, delegate: nil)
    }

    override func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        onUserInitiatedUpdateCheck?()
        super.showUserInitiatedUpdateCheck(cancellation: cancellation)
    }

    override func showUpdateFound(with appcastItem: SUAppcastItem,
                                  state: SPUUserUpdateState,
                                  reply: @escaping (SPUUserUpdateChoice) -> Void) {
        if !shouldUseCustomUpdateWindow(for: appcastItem, state: state) {
            super.showUpdateFound(with: appcastItem, state: state, reply: reply)
            return
        }

        let themeProvider = currentWindowThemeProvider()

        closeUpdateWindow()
        super.dismissUpdateInstallation()

        let windowController = PhiSparkleUpdateWindowController(
            appcastItem: appcastItem,
            mode: windowMode(for: state),
            automaticDownloadsEnabled: updater?.automaticallyDownloadsUpdates ?? false,
            allowsAutomaticUpdates: updater?.allowsAutomaticUpdates ?? true,
            themeProvider: themeProvider,
            activatesApplicationOnShow: state.userInitiated
        )

        var didReply = false
        // Keep weak references behind a stable context so Release WMO does not
        // lower a choice-bearing closure with direct weak captures.
        let context = UpdateChoiceContext(driver: self, windowController: windowController)
        let finish: (SPUUserUpdateChoice) -> Void = { [context] choice in
            guard !didReply else { return }
            didReply = true
            context.driver?.persistAutomaticDownloadsPreference(from: context.windowController)
            if choice == .install {
                context.driver?.closeUpdateWindow()
                reply(choice)
            } else {
                reply(choice)
                context.driver?.closeUpdateWindow()
            }
        }

        windowController.onSkip = { finish(.skip) }
        windowController.onDismiss = { finish(.dismiss) }
        windowController.onInstall = { finish(.install) }

        updateWindowController = windowController
        windowController.showWindow(nil)
    }

    override func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        if let updateWindowController {
            updateWindowController.showReleaseNotes(downloadData)
        } else {
            super.showUpdateReleaseNotes(with: downloadData)
        }
    }

    override func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {
        if let updateWindowController {
            updateWindowController.showReleaseNotesError(error)
        } else {
            super.showUpdateReleaseNotesFailedToDownloadWithError(error)
        }
    }

    override func dismissUpdateInstallation() {
        closeUpdateWindow()
        super.dismissUpdateInstallation()
    }

    override func showUpdateInFocus() {
        if let updateWindowController {
            NSApp.activate(ignoringOtherApps: true)
            updateWindowController.window?.makeKeyAndOrderFront(nil)
        } else {
            super.showUpdateInFocus()
        }
    }

    override func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        closeUpdateWindow()
        super.showUpdaterError(error, acknowledgement: acknowledgement)
    }

    private func persistAutomaticDownloadsPreference(from windowController: PhiSparkleUpdateWindowController?) {
        guard let updater, updater.allowsAutomaticUpdates else { return }
        updater.automaticallyDownloadsUpdates = windowController?.automaticallyDownloadsEnabled ?? false
    }

    private func closeUpdateWindow() {
        updateWindowController?.close()
        updateWindowController = nil
    }

    private func shouldUseCustomUpdateWindow(for appcastItem: SUAppcastItem, state: SPUUserUpdateState) -> Bool {
        guard state.stage == .notDownloaded || state.stage == .downloaded || state.stage == .installing else { return false }
        guard !appcastItem.isInformationOnlyUpdate else { return false }
        guard !appcastItem.isCriticalUpdate else { return false }
        guard !appcastItem.isMajorUpgrade else { return false }
        return true
    }

    private func windowMode(for state: SPUUserUpdateState) -> PhiSparkleUpdateWindowMode {
        if state.stage == .installing {
            return .readyToInstall
        }

        return .available
    }

    private func currentWindowThemeProvider() -> ThemeStateProvider {
        if let context = NSApp.keyWindow?.browserThemeContext {
            return context
        }

        if let context = NSApp.mainWindow?.browserThemeContext {
            return context
        }

        for window in NSApp.orderedWindows {
            if let context = window.browserThemeContext {
                return context
            }
        }

        return ThemeManager.shared
    }
}
#endif

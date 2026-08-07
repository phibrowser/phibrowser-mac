// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

#if !PHI_OSS_BUILD
import Foundation
import Sparkle

extension Notification.Name {
    static let sparkleDidDownloadUpdate = Notification.Name("SparkleDidDownloadUpdate")
    static let sparkleDidSkipUpdate = Notification.Name("SparkleDidSkipUpdate")
}

extension AppController: SPUUpdaterDelegate {
    static var debugSparkle = false
    
    @MainActor @objc func checkForUpdate(_ sender: Any?) {
        guard let updater, updater.canCheckForUpdates else { return }
        updater.checkForUpdates()
    }
    
    @MainActor
    func setupSparkle() {
        let userDriver = PhiSparkleUserDriver()
        let updater = SPUUpdater(
            hostBundle: Bundle.main,
            applicationBundle: Bundle.main,
            userDriver: userDriver,
            delegate: self
        )
        userDriver.updater = updater
        userDriver.onUserInitiatedUpdateCheck = { [weak self] in
            self?.updateState = .checking
        }
        sparkleUserDriver = userDriver
        self.updater = updater

        updater.automaticallyChecksForUpdates = true

        do {
            try updater.start()
        } catch {
            AppLogError("Sparkle: failed to start updater: \(error.localizedDescription)")
        }
    }
    
    func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with request: NSMutableURLRequest) {
        updateState = .downloading(item.displayVersionString)
        AppLogInfo("Sparkle: willDownload update item: \(item.displayVersionString) - \(item.versionString)")
    }
    
    
    func updater(_ updater: SPUUpdater, failedToDownloadUpdate item: SUAppcastItem, error: any Error) {
        self.updateState = .idle
        AppLogError(error.localizedDescription)
    }
    
    func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
        self.updateState = .downloaded(item.displayVersionString)
        AppLogInfo("Sparkle: didDownload update item: \(item.displayVersionString) - \(item.versionString)")
    }
    
    func updaterShouldRelaunchApplication(_ updater: SPUUpdater) -> Bool {
        // Stop the watchdog BEFORE requesting termination so it does not
        // relaunch Sentinel during the Sparkle install (which would recreate
        // the "Sentinel survives the OTA" bug).
        MainActor.assumeIsolated { SentinelWatchdog.shared.stop() }
        SentinelHelper.requestTerminationForBrowserUpdate()
        return true
    }
    
    func userDidCancelDownload(_ updater: SPUUpdater) {
        updateState = .idle
    }
    
    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        updateState = .idle
        AppLogWarn("Sparkle: updaterDidNotFindUpdate with error: \(error.localizedDescription)")
    }
    
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        updateState = .updateAvailable(item.displayVersionString)
        AppLogInfo("Sparkle: did find new update: \(item.displayVersionString) - \(item.versionString)")
    }
    
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        updateState = .idle
        AppLogWarn("Sparkle: didAbortWithError: \(error.localizedDescription)")
    }

    func updater(_ updater: SPUUpdater,
                 userDidMake choice: SPUUserUpdateChoice,
                 forUpdate item: SUAppcastItem,
                 state: SPUUserUpdateState) {
        switch choice {
        case .dismiss:
            if state.stage == .downloaded {
                updateState = .downloaded(item.displayVersionString)
            }
        case .skip:
            updateState = .updateAvailable(item.displayVersionString)
            NotificationCenter.default.post(name: .sparkleDidSkipUpdate, object: self)
        case .install:
            break
        @unknown default:
            break
        }
    }
    
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        updateState = .downloaded(item.displayVersionString)
        NotificationCenter.default.post(
            name: .sparkleDidDownloadUpdate,
            object: self,
            userInfo: [
                "displayVersion": item.displayVersionString,
                "version": item.versionString
            ]
        )
        return false
    }
}

extension AppController {
    enum UpdateState {
        case idle
        case checking
        case updateAvailable(String)
        case downloading(String)
        case downloaded(String)
    }
    
    static let checkForUpdateItemTag = 50001
    
    func updateCheckForUpdateMenuItem() {
        guard let mainMenu = NSApp.mainMenu,
              let menu = ChromiumMainMenuRole.app.item(in: mainMenu)?.submenu else { return }
        guard let item = menu.item(withTag: Self.checkForUpdateItemTag) else { return }
        
        func setupBadgeView(title: String, badge: String) {
            item.title = title
            let badge = NSMenuItemBadge(string: badge)
            item.badge = badge
            
        }
        
        switch updateState {
        case .idle:
            item.isEnabled = true
            item.title = NSLocalizedString("updates.menu.checkForUpdatesStatus", value: "Check for Update...", comment: "Phi menu - Menu item text when no update operation is active")
        case .checking:
            item.isEnabled = false
            item.title = NSLocalizedString("updates.menu.checkingStatus", value: "Checking for updates...", comment: "Phi menu - Menu item text while checking for updates")
        case .updateAvailable(let version):
            item.isEnabled = true
            setupBadgeView(title: NSLocalizedString("updates.menu.availableStatus", value: "New version available", comment: "Phi menu - Menu item text when new version is available"), badge: version)
        case .downloading(let version):
            item.isEnabled = false
            setupBadgeView(title: NSLocalizedString("updates.menu.downloadingStatus", value: "Downloading update...", comment: "Phi menu - Menu item text while downloading update"), badge: version)
        case .downloaded(let version):
            item.isEnabled = true
            setupBadgeView(title: NSLocalizedString("updates.menu.readyToInstallStatus", value: "Click to install update", comment: "Phi menu - Menu item text when update is ready to install"), badge: version)
        }
    }
}
#endif

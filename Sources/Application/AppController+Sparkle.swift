// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import Sparkle

extension Notification.Name {
    static let sparkleDidDownloadUpdate = Notification.Name("SparkleDidDownloadUpdate")
}

extension AppController: SPUUpdaterDelegate {
    static var immediatelyInstallHandler: (() -> Void)?
    static var pendingUpdateItem: SUAppcastItem?
    static var debugSparkle = false
    
    @objc func checkForUpdate(_ sender: Any?) {
        if Self.immediatelyInstallHandler != nil, let item = Self.pendingUpdateItem {
            let result = showInstallAvailableAlert(version: item.displayVersionString)
            if result == .alertFirstButtonReturn {
                installUpdateImmediately()
            }
            return
        }
        
        self.updateState = .checking
        updaterController?.checkForUpdates(sender)
    }
    
    func setupSparkle() {
        updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
        guard let updater = updaterController?.updater else { return }
        updater.automaticallyChecksForUpdates = true
        updater.automaticallyDownloadsUpdates = true
       
        #if !DEBUG
        updater.checkForUpdatesInBackground()
        #endif
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
        NotificationCenter.default.post(
            name: .sparkleDidDownloadUpdate,
            object: self,
            userInfo: [
                "displayVersion": item.displayVersionString,
                "version": item.versionString
            ]
        )
    }
    
    func updaterShouldRelaunchApplication(_ updater: SPUUpdater) -> Bool {
        SentinelHelper.terminateAll()
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
    
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        updateState = .downloaded(item.displayVersionString)
        #if DEBUG
        return false
        #else
        Self.pendingUpdateItem = item
        Self.immediatelyInstallHandler = immediateInstallHandler
        return true
        #endif // DEBUG
    }
}

extension AppController {
    func showInstallAvailableAlert(version: String) -> NSApplication.ModalResponse {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Install Update", comment: "Update alert - Title for install update confirmation dialog")
        alert.informativeText = String(format: NSLocalizedString("Are you sure you want to install version %@ and restart Phi?", comment: "Update alert - Message asking user to confirm update installation with version number"), version)
        alert.alertStyle = .informational
        alert.icon = NSImage(systemSymbolName: "arrow.clockwise.circle", accessibilityDescription: "Update")
        
        alert.addButton(withTitle: NSLocalizedString("Install and Restart", comment: "Update alert - Button to install update and restart the app"))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Update alert - Button to cancel update installation"))
        
        alert.buttons.first?.keyEquivalent = "\r"
        
        let response = alert.runModal()
        return response
    }
    
    func installUpdateImmediately() {
        AppController.immediatelyInstallHandler?()
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
        guard let menu = NSApp.mainMenu?.item(withTitle: "Phi")?.submenu else { return }
        guard let item = menu.item(withTag: Self.checkForUpdateItemTag) else { return }
        
        func setupBadgeView(title: String, badge: String) {
            item.title = title
            let badge = NSMenuItemBadge(string: badge)
            item.badge = badge
            
        }
        
        switch updateState {
        case .idle:
            item.isEnabled = true
            item.title = NSLocalizedString("Check for Update...", comment: "Phi menu - Menu item to check for app updates")
        case .checking:
            item.isEnabled = false
            item.title = NSLocalizedString("Checking for updates...", comment: "Phi menu - Menu item text while checking for updates")
        case .updateAvailable(let version):
            item.isEnabled = true
            setupBadgeView(title: NSLocalizedString("New version available", comment: "Phi menu - Menu item text when new version is available"), badge: version)
        case .downloading(let version):
            item.isEnabled = false
            setupBadgeView(title: NSLocalizedString("Downloading update...", comment: "Phi menu - Menu item text while downloading update"), badge: version)
        case .downloaded(let version):
            item.isEnabled = true
            setupBadgeView(title: NSLocalizedString("Click to install update", comment: "Phi menu - Menu item text when update is ready to install"), badge: version)
        }
    }
}

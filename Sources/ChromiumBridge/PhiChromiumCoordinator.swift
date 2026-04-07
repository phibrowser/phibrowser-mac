// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import Foundation
@objc class PhiChromiumCoordinator: NSObject {
    @objc static var shared = PhiChromiumCoordinator()
}

extension PhiChromiumCoordinator: PhiChromiumBridgeDelegate {
    func shouldEnablePhiExtensions() -> Bool { PhiPreferences.AISettings.phiAIEnabled.loadValue() }
    
    func handleExtensionMessage(_ type: String, payload: String, requestId: String, senderId: String) -> String? {
        return ExtensionMessageRouter.shared.handle(type: type, payload: payload, requestId: requestId)
    }

    func toggleChatSidebar(_ show: NSNumber?) {
        guard let state = MainBrowserWindowControllersManager.shared.activeWindowController?.browserState else {
            return
        }
        if let show {
            state.toggleAIChat(!show.boolValue)
        } else {
            state.toggleAIChat()
        }
    }

    func showFeedbackDialog() {
        MainBrowserWindowControllersManager.shared.activeWindowController?.showFeedbackWindow()
    }

    func downloadEventOccurred(_ eventType: DownloadEventType, guid: String, downloadItem: (any DownloadItemWrapper)?) {
        let eventName: String
        switch eventType {
        case .created: eventName = "CREATED"
        case .updated: eventName = "UPDATED"
        case .completed: eventName = "COMPLETED"
        case .cancelled: eventName = "CANCELLED"
        case .interrupted: eventName = "INTERRUPTED"
        case .paused: eventName = "PAUSED"
        case .resumed: eventName = "RESUMED"
        case .removed: eventName = "REMOVED"
        case .destroyed: eventName = "DESTROYED"
        case .opened: eventName = "OPENED"
        @unknown default: eventName = "UNKNOWN"
        }
        
        if let item = downloadItem {
            AppLogDebug("📥 [Download] Event: \(eventName), GUID: \(guid), File: \(item.fileNameToReportUser), Progress: \(item.percentComplete)%, State: \(item.state), Speed: \(item.currentSpeed) B/s")
        } else {
            AppLogDebug("📥 [Download] Event: \(eventName), GUID: \(guid), Item: nil")
        }
        
        // Downloads are profile-scoped, so every open window needs the update.
        for controller in MainBrowserWindowControllersManager.shared.getAllWindows() {
            controller.browserState.downloadsManager.handleDownloadEvent(
                eventType: eventType,
                guid: guid,
                wrapper: downloadItem
            )
        }
    }
    
    func keyEquivalentOverride(forCommand commandId: Int32) -> [String : Any]? {
        guard let state = Shortcuts.overrideState(for: Int(commandId)) else {
            return nil
        }
        
        if let key = state {
            return [
                "keyEquivalent": key.characters,
                "modifierFlags": key.modifiersRaw
            ]
        } else {
            // An explicit disabled override is represented by an empty shortcut payload.
            return [
                "keyEquivalent": "",
                "modifierFlags": 0
            ]
        }
    }
    
    func getNativeSettings() -> String {
        return PhiPreferences.AISettings.buildConfig()
    }
    
    func handleDeeplink(withUrlString urlString: String, windowId: Int64) -> Bool {
        return DeeplinkHandler.handle(urlString)
    }
    
    func importStarted(_ browserType: BrowserType) {
        AppLogDebug("importStarted type: \(browserType)")
    }
    
    func importItemProgress(_ browserType: BrowserType, started: Bool) {
        AppLogDebug("importItemProgress type: \(browserType), started: \(started)")
    }
    
    func importCompleted(_ browserType: BrowserType, success: Bool) {
        AppLogDebug("importCompleted type: \(browserType), success: \(success)")
        
        NotificationCenter.default.post(
            name: .browserImportCompleted,
            object: nil,
            userInfo: [
                "browserType": browserType.rawValue,
                "success": success
            ]
        )
    }
    
    func isUserLoggedIn() -> Bool {
        let isLoggedIn = AuthManager.shared.checkLoginStatusOnChromiumLaunch()
        AppLogInfo("🌐 [Chromium] isUserLoggedIn check: \(isLoggedIn)")
        return isLoggedIn
    }
    
    func showLoginUI() {
        AppLogInfo("🌐 [Chromium] showLoginUI called by Chromium")
        Task { @MainActor in
            LoginController.shared.showLoginWindow()
        }
    }
    
    func getAuth0AccessTokenSyncly() -> String {
        let token = AuthManager.shared.getAccessTokenSyncly() ?? ""
        let hasToken = !token.isEmpty
        AppLogInfo("🌐 [Chromium] getAuth0AccessTokenSyncly called - hasToken: \(hasToken)")
        return token
    }
    
    func mainBrowserWindowCreated(_ window: NSWindow, type browserType: ChromiumBrowserType, profileId: String, windowId: Int64) {
        AppLogInfo("🌐 [Chromium] mainBrowserWindowCreated called - windowId: \(windowId), type: \(browserType.rawValue)")


        guard browserType == .normal || browserType == .incognito || browserType == .shadow else {
            AppLogInfo("🌐 [Chromium] Ignoring window type: \(browserType.rawValue) (not normal or incognito)")
            return
        }

        // Check login status BEFORE creating window controller
        let userLoggedIn = isUserLoggedIn()

        if userLoggedIn, MainBrowserWindowControllersManager.shared.findControllerWith(window: window) == nil {
            let mainWindowController = MainBrowserWindowController(
                window: window,
                windowId: Int(windowId),
                browserType: browserType,
                profileId: profileId
            )
            if browserType != .shadow {
                mainWindowController.window?.makeKeyAndOrderFront(nil)
            } else {
                AppLogInfo("🌐 Shadow window controller initialized but hidden.")
            }
            AppLogInfo("🌐 [Chromium] ✅ Window controller created and displayed (user logged in)")
        } else {
            AppLogInfo("🌐 [Chromium] User not logged in, adding window as dangling window")
            MainBrowserWindowControllersManager.shared.addDanglingWindow(
                window,
                windowId: Int(windowId),
                browserType: browserType,
                profileId: profileId
            )
            
            DispatchQueue.main.async {
                LoginController.shared.showLoginWindow()
                if let loginWindow = LoginController.shared.loginWindowController?.window {
                    loginWindow.makeKeyAndOrderFront(nil)
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
            AppLogInfo("🌐 [Chromium] ✅ Window stored as dangling, login window will be shown")
        }
    }
    
    var extensionChangedCallback: (([[AnyHashable : Any]], Int64) -> Void)? {
        return { extensions ,windowId in
            EventBus.shared.send(ExtensionEvent(browserId: windowId.intValue, action: .extensionChanged(info: extensions)))
        }
    }
    
    func newTabCreated(withInfo tabInfo: [AnyHashable : Any], windowId: Int64) {
        AppLogDebug("[Tab] newTabCreated: \(tabInfo) \n, windowId: \(windowId)")
        
        let title = tabInfo["title"] as? String
        let url = tabInfo["url"] as? String
        let index = tabInfo["index"] as? Int ?? -1
        let id = tabInfo["id"] as? Int ?? -1
        let active = false // fixeme
        let contentView = tabInfo["webView"] as? (WebContentWrapper & NSObject)
        let customGuid = tabInfo["customGuid"] as? String
        let tab = Tab(guid: id,
                      url: url,
                      isActive: active,
                      index: index,
                      title: title,
                      webContentView: contentView,
                      customGuid: customGuid,
                      windowId: Int(windowId))
        
        if MainBrowserWindowControllersManager.shared.hasDanglingWindow(for: windowId.intValue) {
            MainBrowserWindowControllersManager.shared.addPendingTabToDanglingWindow(tab, windowId: windowId.intValue)
            AppLogInfo("🪟 [Chromium] Tab added to dangling window pending tabs - windowId: \(windowId), tabGuid: \(id)")
        } else {
            EventBus.shared
                .send(TabEvent(browserId: windowId.intValue,
                               action: .newTab(tab)))
        }
    }
    
    func tabWillBeRemove(_ tabId: Int64, windowId: Int64) {
        AppLogDebug("tabWillBeRemove: \(tabId)")
        EventBus.shared
            .send(TabEvent(browserId: windowId.intValue,
                           action: .closeTab(tabId.intValue)))
    }
    
    func getWebContentSuperView() -> NSView? {
        return nil
    }
    
    
    func tabTitleUpdated(_ tabId: Int64, title: String, windowId: Int64) {
        EventBus.shared
            .send(TabEvent(browserId: windowId.intValue,
                           action: .updateTabTitle(tabId: tabId.intValue, newTitle: title)))
    }
    
    @objc func initApplication() {
        enum _Store {
            static var app: AppController?
        }
        let controller = AppController()
        _Store.app = controller
        NSApp = PhiApplication.shared
        NSApp.delegate = controller
        controller.startObservingMainMenu()
    }
    
    func runQuitConfirmAlert() -> Bool {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Quit Phi?", comment: "Quit Phi?")
        alert.addButton(withTitle: NSLocalizedString("Quit", comment: "Quit"))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Cancel"))
        let response = alert.runModal()
        return response == .alertFirstButtonReturn
    }
    
    func activeTabChanged(_ tabId: Int64, index: Int32, windowId: Int64) {
        AppLogDebug("[Tab]: activeTabChanged: \(tabId), atIndex:\(index), window:\(windowId)")
        EventBus.shared
            .send(TabEvent(browserId: windowId.intValue,
                         action: .focusTabWithTabId(tabId.intValue)))
    }
    
    func tabIndicesUpdated(_ tabIndices: [NSNumber : NSNumber], windowId: Int64) {
        AppLogDebug("[Tab] tabIndicesUpdated: \(tabIndices)")
        let map: [Int: Int] = tabIndices.reduce(into: [:]) { partialResult, element in
            partialResult[element.key.intValue] = element.value.intValue
        }
        // FIXME: Chromium `TabsProxy::UpdateTabIndices` does not provide a window id yet, so this
        // currently falls back to the active window.
        let windowId = MainBrowserWindowControllersManager.shared.activeWindowController?.windowId
        if let windowId {
            EventBus.shared
                .send(TabEvent(browserId: windowId,
                             action: .updateTabIndex(map)))
        }
    }

    // =========================================================================
    // Flicker fix: Tab visibility synchronization
    // =========================================================================

    /// Called by Chromium after hiding the previous WebContents.
    /// Mac should clean up the previous tab's NSView from the view hierarchy.
    func previousTabReady(forCleanup tabId: Int64, windowId: Int64) {
        AppLogDebug("[Tab] previousTabReadyForCleanup: tabId=\(tabId), windowId=\(windowId)")
        EventBus.shared
            .send(TabEvent(browserId: windowId.intValue,
                           action: .previousTabReadyForCleanup(tabId.intValue)))
    }

    /// Called by Chromium when a new tab has completed its first visually non-empty paint.
    /// Mac should bring the new tab's view to the front.
    func tabReady(toDisplay tabId: Int64, windowId: Int64) {
        // AppLogDebug("[FlickerFix][Coordinator] tabReadyToDisplay: tabId=\(tabId), windowId=\(windowId)")
        EventBus.shared
            .send(TabEvent(browserId: windowId.intValue,
                           action: .tabReadyToDisplay(tabId.intValue)))
    }

    func targetURLChanged(_ tabId: Int64, windowId: Int64, url: String) {
        guard let windowController = MainBrowserWindowControllersManager.shared
            .getAllWindows()
            .first(where: { $0.windowId == Int(windowId) }) else {
            return
        }

        DispatchQueue.main.async {
            let shouldDisplay = !url.isEmpty &&
                              !url.hasPrefix("about:") &&
                              !url.hasPrefix("chrome:")
            windowController.browserState.targetURL = shouldDisplay ? url : ""
        }
    }
}

extension PhiChromiumCoordinator {
    func dispatchCommand(_ commandId: Int32, window: NSWindow) -> Bool {
        return CommandDispatcher.dispatchCommand(commandId, window: window)
    }
    
    func commandDispatch(_ sender: Any, window: NSWindow) -> Bool {
        return CommandDispatcher.dispatchCommand(sender, window: window)
    }
    
    func handleKeyEquivalent(_ event: NSEvent, window: NSWindow) -> Bool {
        return false
    }
}

extension PhiChromiumCoordinator {
    func extensionsLoaded(_ extensions: [[AnyHashable : Any]]) {

    }
    
    func extensionTriggered(_ extensionId: String) {

    }
    
    func extensionPinned(_ extensionId: String) {

    }
    
    func extensionUnpinned(_ extensionId: String) {

    }
    
    func extensionMoved(_ extensionId: String, to newIndex: Int32) {

    }

    func extensionInstallResult(_ extensionId: String, status: String) {
    }

}

extension PhiChromiumCoordinator {
    func bookmarksLoaded(_ windowId: Int64) {
        EventBus.shared.send(BookmarkEvent(browserId: windowId.intValue,
                                           action: .bookmarksLoaded))
    }
    
    func bookmarksChanged(_ newNodes: [any BookmarkWrapper], windowId: Int64) {
        EventBus.shared.send(BookmarkEvent(browserId: windowId.intValue,
                                           action: .bookmarksChanged(newNodes)))
    }
    
    func bookmarkInfoChanged(withWindowId windowId: Int64, bookmarkId id: Int64, title: String?, url: String?, facicon favicon_url: String?) {
        EventBus.shared.send(BookmarkEvent(browserId: windowId.intValue,
                                           action: .bookmarkInfoChanged(id: id, title: title, url: url, faviconUrl: favicon_url)))
    }
}

extension PhiChromiumCoordinator {
    func omniboxResultChanged(_ matches: [[AnyHashable : Any]], originalInput: String, windowId: Int64) {
        guard let infos = matches as? [[String: Any]] else {
            return
        }
        EventBus.shared.send(OmniEvent(browserId: Int(windowId),
                                       action: .searchSuggestionResultChanged(suggestions: infos,
                                                                              originalInput: originalInput)))
    }
}

extension Int64 {
    var intValue: Int { Int(self) }
}

extension Int {
    var int64Value: Int64 { Int64(self) }
}

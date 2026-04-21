// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import Foundation

/// Persists and restores per-account browser window snapshots.
final class BrowserRestoreManager {
    static let shared = BrowserRestoreManager()
    
    private static let logPrefix = "🪟 [Restore]"
    private var store: BrowserRestoreStore?
    private var pendingState: BrowserRestoreState?
    private var hasAttemptedRestore = false
    private var accountObserver: NSObjectProtocol?
    private var currentAccount: Account = AccountController.defaultAccount
    
    private init() {}
    
    func startObserving() {
        AppLogInfo("\(Self.logPrefix) startObserving")
        if accountObserver == nil {
            accountObserver = NotificationCenter.default.addObserver(
                forName: .mainAccountChanged,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                AppLogInfo("\(Self.logPrefix) account changed")
                self?.reloadStateForCurrentAccount()
                self?.restoreIfReady()
            }
        }
        
        reloadStateForCurrentAccount()
        restoreIfReady()
    }
    
    @MainActor
    func saveSnapshotIfNeeded() {
        let account = AccountController.shared.account ?? AccountController.defaultAccount
        let store = BrowserRestoreStore(account: account)
        
        let controllers = MainBrowserWindowControllersManager.shared.getAllWindows()
        AppLogInfo("\(Self.logPrefix) snapshot start windows=\(controllers.count)")
        let windowStates = controllers
            .filter{ $0.browserType == .normal}
            .compactMap { controller in
                makeWindowState(from: controller)
            }
        
        if windowStates.isEmpty {
            AppLogInfo("\(Self.logPrefix) snapshot empty, clearing store")
            store.clear()
            return
        }
        
        let state = BrowserRestoreState(
            version: BrowserRestoreState.currentVersion,
            windows: windowStates,
            savedAt: Date()
        )
        store.save(state)
        AppLogInfo("\(Self.logPrefix) snapshot saved windows=\(windowStates.count)")
    }
    
    private func reloadStateForCurrentAccount() {
        currentAccount = AccountController.shared.account ?? AccountController.defaultAccount
        store = BrowserRestoreStore(account: currentAccount)
        pendingState = store?.load()
        hasAttemptedRestore = false
        if let pendingState {
            AppLogInfo("\(Self.logPrefix) loaded pending state windows=\(pendingState.windows.count)")
        } else {
            AppLogInfo("\(Self.logPrefix) no pending state")
        }
    }
    
    private func restoreIfReady() {
        Task { @MainActor in
            guard LoginController.shared.phase == .done else { return }
            restoreIfNeeded()
        }
    }
    
    @MainActor
    private func restoreIfNeeded() {
        guard !hasAttemptedRestore else { return }
        guard let state = pendingState, !state.windows.isEmpty else { return }
        hasAttemptedRestore = true
        
        AppLogInfo("\(Self.logPrefix) restore start windows=\(state.windows.count)")
        var reusableControllers = MainBrowserWindowControllersManager.shared.getAllWindows()
        for (index, windowState) in state.windows.enumerated() {
            if !reusableControllers.isEmpty {
                let controller = reusableControllers.removeFirst()
                AppLogInfo("\(Self.logPrefix) reuse window windowId=\(controller.windowId) index=\(index)")
                restoreWindow(windowState, in: controller)
            } else {
                restoreWindow(windowState, in: nil)
            }
        }
        
        store?.clear()
        pendingState = nil
        AppLogInfo("\(Self.logPrefix) restore complete")
    }
    
    @MainActor
    private func restoreWindow(_ windowState: BrowserRestoreWindowState, in existingController: MainBrowserWindowController?) {
        let browserType = ChromiumBrowserType(rawValue: UInt(windowState.browserTypeRawValue)) ?? .normal
        let controller: MainBrowserWindowController
        
        if let existingController {
            controller = existingController
            AppLogInfo("\(Self.logPrefix) restore into existing window windowId=\(controller.windowId) tabs=\(windowState.tabs.count)")
        } else {
            guard let bridge = ChromiumLauncher.sharedInstance().bridge else { return }
            AppLogInfo("\(Self.logPrefix) create window type=\(browserType.rawValue) tabs=\(windowState.tabs.count)")
            let info = bridge.createBrowser(withWindowType: browserType)
            
            guard let window = info["window"] as? NSWindow,
                  let windowIdNumber = info["windowId"] as? NSNumber else {
                AppLogError("\(Self.logPrefix) failed to create window from bridge response")
                return
            }
            
            let windowId = windowIdNumber.intValue
            if let existing = MainBrowserWindowControllersManager.shared.findControllerWith(window: window) {
                controller = existing
                AppLogInfo("\(Self.logPrefix) window controller already exists windowId=\(windowId)")
            } else {
                AppLogInfo("\(Self.logPrefix) window created windowId=\(windowId)")
                controller = MainBrowserWindowController(
                    window: window,
                    windowId: windowId,
                    browserType: browserType,
                    profileId: windowState.profileId,
                    account: currentAccount
                )
            }
        }
        
        if let window = controller.window {
            window.setFrame(windowState.frame.rect, display: true)
            window.makeKeyAndOrderFront(nil)
            AppLogInfo("\(Self.logPrefix) window frame restored windowId=\(controller.windowId)")
        }
        
        restoreTabs(in: controller, windowState: windowState)
    }
    
    @MainActor
    private func restoreTabs(in controller: MainBrowserWindowController, windowState: BrowserRestoreWindowState) {
        let focusIndex = windowState.selectedIndex
        let restorableTabCount = windowState.tabs.reduce(into: 0) { count, tabState in
            if !tabState.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                count += 1
            }
        }
        AppLogInfo("\(Self.logPrefix) restore tabs start windowId=\(controller.windowId) focusIndex=\(String(describing: focusIndex))")
        controller.browserState.prepareForRestoredTabs(expectedCount: restorableTabCount)
        
        for (index, tabState) in windowState.tabs.enumerated() {
            let trimmedURL = tabState.url.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedURL.isEmpty else { continue }
            let customGuid = tabState.customGuid?.isEmpty == false ? tabState.customGuid : nil
            let shouldFocus = focusIndex == index
            AppLogInfo("\(Self.logPrefix) create tab windowId=\(controller.windowId) index=\(index) focus=\(shouldFocus) url=\(trimmedURL) customGuid=\(customGuid ?? "nil")")
            controller.browserState.createTab(trimmedURL, customGuid: customGuid, focusAfterCreate: shouldFocus)
        }
        
        AppLogInfo("\(Self.logPrefix) restore tabs done windowId=\(controller.windowId)")
    }
    
    @MainActor
    private func makeWindowState(from controller: MainBrowserWindowController) -> BrowserRestoreWindowState? {
        guard let window = controller.window else { return nil }
        let tabs = controller.browserState.tabs
        guard !tabs.isEmpty else { return nil }
        
        let tabStates = tabs
            .filter { !$0.isNTP }
            .map { tab in
                let url = (tab.url?.isEmpty == false) ? tab.url! : "chrome://newtab/"
                let customGuid = tab.guidInLocalDB?.isEmpty == false ? tab.guidInLocalDB : nil
                return BrowserRestoreTabState(url: url, customGuid: customGuid)
            }
        
        let selectedIndex = controller.browserState.focusingTab.flatMap { focusingTab in
            tabs.firstIndex(where: { $0.guid == focusingTab.guid })
        }
        AppLogInfo("\(Self.logPrefix) capture window windowId=\(controller.windowId) tabs=\(tabs.count) selectedIndex=\(String(describing: selectedIndex))")
        
        return BrowserRestoreWindowState(
            browserTypeRawValue: Int(controller.browserType.rawValue),
            profileId: controller.browserState.profileId,
            frame: BrowserRestoreWindowFrame(frame: window.frame),
            tabs: tabStates,
            selectedIndex: selectedIndex
        )
    }
}

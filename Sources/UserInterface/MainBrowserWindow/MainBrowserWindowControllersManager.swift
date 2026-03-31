// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import Foundation

protocol MainBrowserWindowLookup {
    func controller(for windowId: Int) -> MainBrowserWindowController?
}

/// Represents a browser window created before user login
/// These windows are held temporarily and will be converted to MainBrowserWindowController after login
struct DanglingWindow {
    let window: NSWindow
    let windowId: Int
    let browserType: ChromiumBrowserType
    let profileId: String
    /// Tabs created before login, will be processed after login
    var pendingTabs: [Tab] = []
}

class MainBrowserWindowControllersManager: MainBrowserWindowLookup {
    static let shared = MainBrowserWindowControllersManager()
    private(set) var activeWindowController: MainBrowserWindowController?
    private var windowControllers: Set<MainBrowserWindowController> = []
    
    /// Windows created before user login, waiting to be converted to MainBrowserWindowController
    private var danglingWindows: [DanglingWindow] = []
    
    private init() {
        // Listen for login completion to process dangling windows
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleLoginCompleted),
            name: .loginCompleted,
            object: nil
        )
    }
    
    /// Add a window that was created before user login
    /// The window will be hidden and stored until login is completed
    /// - Parameters:
    ///   - window: The NSWindow created by Chromium
    ///   - windowId: The window identifier
    ///   - browserType: The type of browser window (normal, incognito, etc.)
    func addDanglingWindow(_ window: NSWindow, windowId: Int, browserType: ChromiumBrowserType, profileId: String) {
        assert(Thread.isMainThread)
        AppLogInfo("🪟 [WindowManager] Adding dangling window - windowId: \(windowId), type: \(browserType.rawValue)")
        
        // Hide the window to prevent it from showing before login
        hideDanglingWindow(window)
        
        let danglingWindow = DanglingWindow(window: window, windowId: windowId, browserType: browserType, profileId: profileId)
        danglingWindows.append(danglingWindow)
        
        AppLogInfo("🪟 [WindowManager] Dangling windows count: \(danglingWindows.count)")
    }
    
    /// Add a pending tab to a dangling window
    /// The tab will be processed after login when the window controller is created
    /// - Parameters:
    ///   - tab: The tab created by Chromium
    ///   - windowId: The window identifier to associate the tab with
    /// - Returns: true if the tab was added to a dangling window, false if no matching window found
    @discardableResult
    func addPendingTabToDanglingWindow(_ tab: Tab, windowId: Int) -> Bool {
        assert(Thread.isMainThread)
        
        guard let index = danglingWindows.firstIndex(where: { $0.windowId == windowId }) else {
            AppLogWarn("🪟 [WindowManager] No dangling window found for windowId: \(windowId)")
            return false
        }
        
        danglingWindows[index].pendingTabs.append(tab)
        AppLogInfo("🪟 [WindowManager] Added pending tab to dangling window - windowId: \(windowId), tabGuid: \(tab.guid), total pending tabs: \(danglingWindows[index].pendingTabs.count)")
        return true
    }
    
    /// Check if a dangling window exists for the given window ID
    /// - Parameter windowId: The window identifier to check
    /// - Returns: true if a dangling window exists for the given ID
    func hasDanglingWindow(for windowId: Int) -> Bool {
        return danglingWindows.contains { $0.windowId == windowId }
    }
    
    /// Hide a dangling window completely
    private func hideDanglingWindow(_ window: NSWindow) {
        // Set window level to behind everything to prevent it from stealing focus
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.minimumWindow)))
        // Hide the window completely
        window.setFrame(NSRect(origin: .zero, size: .zero), display: false)
        window.setIsVisible(false)
        window.alphaValue = 0
        window.orderOut(nil)
    }
    
    /// Process all dangling windows after login completion
    @objc private func handleLoginCompleted() {
        assert(Thread.isMainThread)
        AppLogInfo("🪟 [WindowManager] Login completed - processing \(danglingWindows.count) dangling window(s)")
        
        for danglingWindow in danglingWindows {
            processDanglingWindow(danglingWindow)
        }
        
        // Clear dangling windows after processing
        danglingWindows.removeAll()
        AppLogInfo("🪟 [WindowManager] All dangling windows processed")
    }
    
    /// Convert a dangling window to a proper MainBrowserWindowController and show it
    private func processDanglingWindow(_ danglingWindow: DanglingWindow) {
        AppLogInfo("🪟 [WindowManager] Processing dangling window - windowId: \(danglingWindow.windowId), pending tabs: \(danglingWindow.pendingTabs.count)")
        guard let account = AccountController.shared.account else {
            AppLogError("No available account")
            return
        }
        // Create the MainBrowserWindowController now that the user is logged in
        let windowController = MainBrowserWindowController(
            window: danglingWindow.window,
            windowId: danglingWindow.windowId,
            browserType: danglingWindow.browserType,
            profileId: danglingWindow.profileId,
            account: account
        )
        
        // Process pending tabs that were created before login
        for tab in danglingWindow.pendingTabs {
            AppLogInfo("🪟 [WindowManager] Processing pending tab - tabGuid: \(tab.guid)")
            if tab.url?.hasPrefix("chrome://newtab") ?? false {
                tab.title = "New Tab"
            }
            windowController.browserState.handleNewTabFromChromium(tab)
        }
        
        if windowController.browserState.focusingTab == nil,
            let last = danglingWindow.pendingTabs.last {
            windowController.browserState.focuseTab(last)
        }
        // Restore and show the window
        windowController.restoreAndShowWindow()
        
        AppLogInfo("🪟 [WindowManager] Dangling window processed and displayed - windowId: \(danglingWindow.windowId)")
    }
    
    func retainWindowControllerUntilWindowClosed(_ windowController: MainBrowserWindowController) {
        assert(Thread.isMainThread)
        guard !windowControllers.contains(windowController), let window = windowController.window else {
            return
        }
        
        if windowControllers.isEmpty {
            activeWindowController = windowController
        }
        
        windowControllers.insert(windowController)
        
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(windowWillClose(_:)),
                                               name: NSWindow.willCloseNotification,
                                               object: window)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(windowDidBecomeKey(_:)),
                                               name: NSWindow.didBecomeKeyNotification,
                                               object: window)
    }
    
    @objc private func windowWillClose(_ noti: NSNotification) {
        guard let window = noti.object as? NSWindow,
              let windowController = window.windowController as? MainBrowserWindowController else {
            return
        }
        windowControllers.remove(windowController)
    }
    
    @objc private func windowDidBecomeKey(_ noti: NSNotification) {
        guard let window = noti.object as? NSWindow,
              let windowController = window.windowController as? MainBrowserWindowController else {
            return
        }
        activeWindowController = windowController
        AppLogDebug("window did become key window: \(windowController.windowId)")
    }
    
    func getBrowserState(for browserId: Int) -> BrowserState? {
        return windowControllers.first(where: { $0.windowId == browserId })?.browserState
    }

    func controller(for windowId: Int) -> MainBrowserWindowController? {
        windowControllers.first(where: { $0.windowId == windowId })
    }
    
    func findControllerWith(window: NSWindow) -> MainBrowserWindowController? {
        return windowControllers.first {  $0.window === window }
    }
    
    func getActiveWindowState() -> BrowserState? { activeWindowController?.browserState }
    
    /// Returns every tracked browser window controller.
    func getAllWindows() -> [MainBrowserWindowController] {
        return Array(windowControllers)
    }
    
    /// Get the first available window ID, checking both active windows and dangling windows
    /// This is useful for operations that need a window ID before login is completed
    /// - Returns: The first available window ID, or nil if no windows exist
    func getFirstAvailableWindowId() -> Int? {
        // First try to get from active window controllers
        if let windowId = windowControllers.first?.windowId {
            return windowId
        }
        // Fallback to dangling windows (windows created before login)
        return danglingWindows.first?.windowId
    }
    
    /// Closes every browser window, for example during logout flows.
    @MainActor
    func closeAllWindows() {
        AppLogInfo("🪟 [WindowManager] closeAllWindows called")
        AppLogInfo("🪟 [WindowManager] Current window count: \(windowControllers.count)")
        
        // Copy first so window teardown cannot mutate the set during iteration.
        let controllers = Array(windowControllers)
        
        // Use `performClose` so Chromium gets the same lifecycle as a user-initiated close.
        for (index, controller) in controllers.enumerated() {
            AppLogInfo("🪟 [WindowManager] Closing window \(index + 1)/\(controllers.count) (windowId: \(controller.windowId))")
            if let window = controller.window {
                window.performClose(nil)
                AppLogInfo("🪟 [WindowManager] Window \(controller.windowId) performClose called")
            } else {
                AppLogInfo("🪟 [WindowManager] Window \(controller.windowId) has no window object")
            }
        }
        
        // Clear the active-window reference once close requests are issued.
        activeWindowController = nil
        AppLogInfo("🪟 [WindowManager] Active window controller cleared")
        AppLogInfo("🪟 [WindowManager] closeAllWindows completed")
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import Cocoa
import SwiftUI

extension AppController {
    static let extensionInfoItemTag = 500002
    static let toggleBookmarkBarItemTag = 500003
    static let toggleBookmarkBarOnNewTabItemTag = 500004
    static let layoutModeDefaultItemTag = 500005
    static let layoutModeNavigationAtTopItemTag = 500006
    static let layoutModeTraditionalItemTag = 500007
    static let layoutModeTitleItemTag = 500008
    static let whatsNewItemTag = 500009
    
    func startObservingMainMenu() {
        guard let app = NSApplication.shared as NSApplication? else {
            AppLogWarn("⚠️ NSApp is nil — startObservingMainMenu() called too early.")
            return
        }
        menuObservation = app.observe(\.mainMenu, options: [.new, .old]) { [weak self] app, change in
            AppLogDebug("Main menu changed: \(change)")
            self?.hookAndRebuildMainMenu()
        }
    }
    
    private func hookAndRebuildMainMenu() {
        guard let mainMenu = NSApp.mainMenu else {
            return
        }
        
        for menuItem in mainMenu.items {
            if let submenu = menuItem.submenu, menuItem.title == "View" {
                submenu.items.forEach {
                    let tag = $0.tag
                    if [40009, 40250, 40259, 40282, 40296, 40251].contains(tag) {
                        $0.isHidden = true
                    }
                }

                submenu.items.removeAll { item in
                    item.tag == CommandWrapper.PHI_TOGGLE_SIDEBAR.rawValue ||
                    item.tag == CommandWrapper.PHI_TOGGLE_CHATBAR.rawValue ||
                    item.tag == AppController.toggleBookmarkBarItemTag ||
                    item.tag == AppController.toggleBookmarkBarOnNewTabItemTag ||
                    item.tag == AppController.layoutModeDefaultItemTag ||
                    item.tag == AppController.layoutModeNavigationAtTopItemTag ||
                    item.tag == AppController.layoutModeTraditionalItemTag ||
                    item.tag == AppController.layoutModeTitleItemTag
                }

                if submenu.items.last?.isSeparatorItem == false {
                    submenu.addItem(NSMenuItem.separator())
                }
                
                let layoutTtitle = NSMenuItem.sectionHeader(title: NSLocalizedString("Layout Mode", comment: "View menu - Layout mode section header in View menu"))
                layoutTtitle.tag = AppController.layoutModeTitleItemTag
                submenu.addItem(layoutTtitle)
                
                let navigationAtTopItem = NSMenuItem(title: LayoutMode.balanced.displayName,
                                                     action: #selector(selectLayoutMode(_:)),
                                                     keyEquivalent: "")
                navigationAtTopItem.tag = AppController.layoutModeNavigationAtTopItemTag
                navigationAtTopItem.target = self
                submenu.addItem(navigationAtTopItem)
                
                let defaultLayoutItem = NSMenuItem(title: LayoutMode.performance.displayName,
                                                   action: #selector(selectLayoutMode(_:)),
                                                   keyEquivalent: "")
                defaultLayoutItem.tag = AppController.layoutModeDefaultItemTag
                defaultLayoutItem.target = self
                submenu.addItem(defaultLayoutItem)

                let traditionalLayoutItem = NSMenuItem(title: LayoutMode.comfortable.displayName,
                                                       action: #selector(selectLayoutMode(_:)),
                                                       keyEquivalent: "")
                traditionalLayoutItem.tag = AppController.layoutModeTraditionalItemTag
                traditionalLayoutItem.target = self
                submenu.addItem(traditionalLayoutItem)

                submenu.addItem(NSMenuItem.separator())
                let toggleBookmarkBarItem = NSMenuItem(title: NSLocalizedString("Always Show Bookmark Bar", comment: "View menu - Menu item to always show the bookmark bar"),
                                                   action: #selector(toggleBookmarkBar(_:)),
                                                   keyEquivalent: "b")
                toggleBookmarkBarItem.keyEquivalentModifierMask = [.command, .shift]
                toggleBookmarkBarItem.tag = AppController.toggleBookmarkBarItemTag
                toggleBookmarkBarItem.target = self
                submenu.addItem(toggleBookmarkBarItem)
                let toggleBookmarkBarOnNewTabItem = NSMenuItem(title: NSLocalizedString("Show Bookmark Bar on New Tab", comment: "View menu - Menu item to show the bookmark bar on new tab pages"),
                                                   action: #selector(toggleBookmarkBarOnNewTab(_:)),
                                                   keyEquivalent: "")
                toggleBookmarkBarOnNewTabItem.tag = AppController.toggleBookmarkBarOnNewTabItemTag
                toggleBookmarkBarOnNewTabItem.target = self
                submenu.addItem(toggleBookmarkBarOnNewTabItem)

                submenu.addItem(NSMenuItem.separator())

                let toggleSidebarItem = NSMenuItem(title: NSLocalizedString("Toggle Sidebar", comment: "View menu - Menu item to show or hide the sidebar"),
                                                   action: #selector(toggleSidebar(_:)),
                                                   keyEquivalent: "s")
                toggleSidebarItem.keyEquivalentModifierMask = [.command]
                toggleSidebarItem.tag = CommandWrapper.PHI_TOGGLE_SIDEBAR.rawValue
                Shortcuts.updateShortcut(for: toggleSidebarItem)
                toggleSidebarItem.target = self
                submenu.addItem(toggleSidebarItem)

                let toggleChatbarItem = NSMenuItem(title: NSLocalizedString("Toggle Chatbar", comment: "View menu - Menu item to show or hide the AI chat bar"),
                                                   action: #selector(toggleChatbar(_:)),
                                                   keyEquivalent: "s")
                toggleChatbarItem.keyEquivalentModifierMask = [.command, .shift]
                toggleChatbarItem.tag = CommandWrapper.PHI_TOGGLE_CHATBAR.rawValue
                Shortcuts.updateShortcut(for: toggleChatbarItem)
                toggleChatbarItem.target = self
                submenu.addItem(toggleChatbarItem)
            } else
            
            if menuItem.title == "Phi", let subMenu = menuItem.submenu {
                subMenu.items.removeAll { $0.tag == AppController.checkForUpdateItemTag }

                for (index, item) in subMenu.items.enumerated() {
                    if item.title == "Settings..." || item.tag == 40015 {
                        let checkForUpdateItem = NSMenuItem(title: NSLocalizedString("Check for Update...", comment: "Phi menu - Menu item to check for app updates"),
                                                           action: #selector(checkForUpdate(_:)),
                                                           keyEquivalent: "")
                        checkForUpdateItem.tag = AppController.checkForUpdateItemTag
                        checkForUpdateItem.target = self
                        subMenu.insertItem(checkForUpdateItem, at: index + 1)
                        break
                    }
                }
            } else
            
            if menuItem.title == "File", let subMenu = menuItem.submenu {
                subMenu.items.forEach { item in
                    if item.tag == CommandWrapper.IDC_SAVE_PAGE.rawValue {
                        item.keyEquivalent = ""
                        item.keyEquivalentModifierMask = .init(rawValue: 0)
                    }
                }
            } else
            
            if menuItem.title == "Profiles" || menuItem.tag == 46100 {
                menuItem.isHidden = true
            } else
                
            if menuItem.title == "Bookmarks" || menuItem.tag == 40029 {
                menuItem.isHidden = true
            } else
            
            if menuItem.title == "Tab", let subMenu = menuItem.submenu {
                let hiddenTitles = ["Pin Tab", "Group Tab", "Move Tab to New Window", "Close Other Tabs", "Close Tabs to the Right"]
                subMenu.items.forEach { item in
                    if hiddenTitles.contains(item.title) {
                        item.isHidden = true
                    }
                }
            } else
            
            if menuItem.title == "Help", let subMenu = menuItem.submenu {
                // Remove existing custom items to avoid duplication on menu rebuild
                subMenu.items.removeAll {
                    $0.tag == AppController.extensionInfoItemTag ||
                    $0.tag == AppController.whatsNewItemTag
                }
                
                let extensionInfoItem = NSMenuItem(title: NSLocalizedString("Extension Info", comment: "Help menu - Menu item to show extension version info, only visible when holding Option key"),
                                                   action: #selector(showExtensionInfo(_:)),
                                                   keyEquivalent: "")
                extensionInfoItem.tag = AppController.extensionInfoItemTag
                extensionInfoItem.isHidden = true
                extensionInfoItem.target = self
                
                if subMenu.items.count > 0 {
                    subMenu.insertItem(extensionInfoItem, at: 0)
                } else {
                    subMenu.addItem(extensionInfoItem)
                }

                let whatsNewItem = NSMenuItem(title: NSLocalizedString("What's New", comment: "Help menu - Menu item that opens the chrome://whats-new page in a new tab, placed right below 'Report an Issue'"),
                                              action: #selector(showWhatsNew(_:)),
                                              keyEquivalent: "")
                whatsNewItem.tag = AppController.whatsNewItemTag
                whatsNewItem.target = self
                // Insert right below the Chromium-provided "Report an Issue" item (IDC_FEEDBACK).
                // Fallback to appending at the end if that item is not present.
                if let reportIssueIndex = subMenu.items.firstIndex(where: { $0.tag == CommandWrapper.IDC_FEEDBACK.rawValue }) {
                    subMenu.insertItem(whatsNewItem, at: reportIssueIndex + 1)
                } else {
                    subMenu.addItem(whatsNewItem)
                }
                
                subMenu.delegate = self
            }
        }
        
        if mainMenu.items.first(where: { $0.title == "*DEBUG*" }) == nil {
            let item = buildDebugMenuItem()
            #if DEBUG || NIGHTLY_BUILD
            mainMenu.addItem(item)
            #else
            if UserDefaults.standard.bool(forKey: PhiPreferences.phiMainDebugMenuEnabled.rawValue) == true {
                mainMenu.addItem(item)
            }
            #endif // DEBUG || NIGHTLY_BUILD
        }
    }
    
    @objc func toggleSidebar(_ sender: Any?) {
        MainBrowserWindowControllersManager.shared.activeWindowController?.browserState.toggleSidebar()
    }
    
    @objc func toggleChatbar(_ sendar: Any?) {
        MainBrowserWindowControllersManager.shared.activeWindowController?.browserState.toggleAIChat()
    }

    @objc func toggleBookmarkBar(_ sender: Any?) {
        let currentValue = PhiPreferences.GeneralSettings.alwaysShowBookmarkBar.loadValue()
        UserDefaults.standard.set(!currentValue, forKey: PhiPreferences.GeneralSettings.alwaysShowBookmarkBar.rawValue)
    }

    @objc func toggleBookmarkBarOnNewTab(_ sender: Any?) {
        let currentValue = PhiPreferences.GeneralSettings.showBookmarkBarOnNewTabPage.loadValue()
        UserDefaults.standard.set(!currentValue, forKey: PhiPreferences.GeneralSettings.showBookmarkBarOnNewTabPage.rawValue)
    }

    @objc func selectLayoutMode(_ sender: Any?) {
        guard let menuItem = sender as? NSMenuItem else { return }

        switch menuItem.tag {
        case AppController.layoutModeDefaultItemTag:
            PhiPreferences.GeneralSettings.saveLayoutMode(.performance)
        case AppController.layoutModeNavigationAtTopItemTag:
            PhiPreferences.GeneralSettings.saveLayoutMode(.balanced)
        case AppController.layoutModeTraditionalItemTag:
            PhiPreferences.GeneralSettings.saveLayoutMode(.comfortable)
        default:
            break
        }
    }
    
    @objc func showWhatsNew(_ sender: Any?) {
        BrowserState.currentState()?.createTab("chrome://whats-new", focusAfterCreate: true)
    }
    
    @objc func showExtensionInfo(_ sender: Any?) {
        let versionsDict = MainBrowserWindowControllersManager.shared.activeWindowController?.browserState.extensionManager.phiExtensionVersions
        
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Extension Info", comment: "Extension info alert - Title of the alert showing extension version information")
        
        let informativeText: String
        if let dict = versionsDict, !dict.isEmpty {
            let lines = dict.sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
                .map { "\($0.key): \($0.value)" }
            informativeText = lines.joined(separator: "\n")
        } else {
            informativeText = NSLocalizedString("No extensions found or versions unavailable.", comment: "Extension info alert - Fallback when no extension versions are available")
        }
        
        alert.informativeText = informativeText
        alert.alertStyle = .informational
        alert.addButton(withTitle: NSLocalizedString("OK", comment: "Extension info alert - OK button to dismiss the alert"))
        alert.runModal()
    }

    // MARK: - Chromium Menu Actions

    @objc func orderFrontStandardAboutPanel(_ sender: Any?) {
        if let existingWindow = NSApp.windows.first(where: { $0.identifier?.rawValue ?? "" == "About Phi Browser" }) {
            existingWindow.makeKeyAndOrderFront(nil)
            return
        }

        let aboutView = AboutView()
        let hostingController = ThemedHostingController(rootView: aboutView)

        let window = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier("About Phi Browser")

        window.contentViewController = hostingController
        window.setContentSize(NSSize(width: 290, height: 180))
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        
    }

    // MARK: - Menu Validation

    @objc func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(toggleChatbar(_:)) {
            let phiAIEnabled = UserDefaults.standard.bool(forKey: PhiPreferences.AISettings.phiAIEnabled.rawValue)
            if !phiAIEnabled || MainBrowserWindowControllersManager.shared.getActiveWindowState()?.isIncognito ?? false || MainBrowserWindowControllersManager.shared.getActiveWindowState()?.focusingTab?.aiChatEnabled == false {
                return false
            }
        }
        
        // Toggle Sidebar is unavailable in the traditional layout.
        if item.action == #selector(toggleSidebar(_:)) {
            if PhiPreferences.GeneralSettings.loadLayoutMode().isTraditional {
                return false
            }
        }
        
        if item.action == #selector(showPreferences(_:)) {
            return LoginController.shared.isLoggedin()
        }
        
        if item.action == #selector(checkForUpdate(_:)) {
            switch updateState {
            case .downloading, .checking:
                return false
            default:
                return true
            }
        }

        if item.action == #selector(selectLayoutMode(_:)) {
            if let menuItem = item as? NSMenuItem {
                let layoutMode = PhiPreferences.GeneralSettings.loadLayoutMode()

                switch menuItem.tag {
                case AppController.layoutModeDefaultItemTag:
                    menuItem.state = (layoutMode == .performance) ? .on : .off
                case AppController.layoutModeNavigationAtTopItemTag:
                    menuItem.state = (layoutMode == .balanced) ? .on : .off
                case AppController.layoutModeTraditionalItemTag:
                    menuItem.state = (layoutMode == .comfortable) ? .on : .off
                default:
                    break
                }
                return LoginController.shared.isLoggedin()
            }
        }

        let traditionalLayout = PhiPreferences.GeneralSettings.loadLayoutMode().isTraditional
        if item.action == #selector(toggleBookmarkBar(_:)) {
            if let menuItem = item as? NSMenuItem {
                if !traditionalLayout {
                    menuItem.isHidden = true
                    return false
                }
                menuItem.isHidden = false
                let isAlwaysShow = PhiPreferences.GeneralSettings.alwaysShowBookmarkBar.loadValue()
                menuItem.state = isAlwaysShow ? .on : .off
                return true
            }
        }
        if item.action == #selector(toggleBookmarkBarOnNewTab(_:)) {
            if let menuItem = item as? NSMenuItem {
                let isAlwaysShow = PhiPreferences.GeneralSettings.alwaysShowBookmarkBar.loadValue()
                if !traditionalLayout || isAlwaysShow {
                    menuItem.isHidden = true
                    return false
                }
                menuItem.isHidden = false
                let isShowOnNewTab = PhiPreferences.GeneralSettings.showBookmarkBarOnNewTabPage.loadValue()
                menuItem.state = isShowOnNewTab ? .on : .off
                return true
            }
        }
        let isLoggedIn = LoginController.shared.isLoggedin()
        if !isLoggedIn {
            let allowedActions: [Selector] = [
                #selector(orderFrontStandardAboutPanel(_:)),
                #selector(NSApplication.terminate(_:)),
                #selector(NSApplication.hide(_:)),
                #selector(NSApplication.hideOtherApplications(_:)),
                #selector(NSApplication.unhideAllApplications(_:)),
                #selector(showSentryDebugWindow(_:)),
                #selector(triggerDeeplink(_:)),
                #selector(clearUserData(_:)),
                #selector(clearLoginStatus(_:)),
                #selector(clearAllUserData(_:))
            ]

            if let action = item.action {
                return allowedActions.contains(action)
            }
            return false
        }

        return true
    }
    
    @IBAction @objc func commandDispatch(_ sender: Any?) {
        
    }
}

// MARK: - NSMenuDelegate for Help menu Option key handling
extension AppController: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        let optionKeyPressed = NSEvent.modifierFlags.contains(.option)
        if let extensionInfoItem = menu.item(withTag: AppController.extensionInfoItemTag) {
            extensionInfoItem.isHidden = !optionKeyPressed
        }
    }
}

// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import Cocoa
import SwiftUI
import UniformTypeIdentifiers

extension AppController {
    static let extensionInfoItemTag = 500002
    static let exportLogsItemTag = 500011
    static let manageUserDataHelpSeparatorTag = 500012
    static let manageUserDataParentItemTag = 500013
    static let timeMachineBackupsParentItemTag = 500014
    static let toggleBookmarkBarItemTag = 500003
    static let toggleBookmarkBarOnNewTabItemTag = 500004
    static let layoutModeDefaultItemTag = 500005
    static let layoutModeNavigationAtTopItemTag = 500006
    static let layoutModeTraditionalItemTag = 500007
    static let layoutModeTitleItemTag = 500008
    static let whatsNewItemTag = 500009
    static let bookmarksMenuItemTag = 500010
    static let bookmarksMenuIdentifier = NSUserInterfaceItemIdentifier("phi.bookmarks.menu")
    static let spacesNewProfileItemTag = 500015
    static let spacesDeleteProfileParentItemTag = 500016
    static let viewMenuSpacesToggleItemTag = 500017
    static let viewMenuSpacesToggleSeparatorTag = 500019
    static let spacesProfileSeparatorTag = 500020
    static let deleteProfileSubmenuIdentifier = NSUserInterfaceItemIdentifier("phi.spaces.deleteProfile")
    static let spacesMenuItemTag = 500018
    static let spacesNewSpaceItemTag = 500030
    static let spacesRenameItemTag = 500031
    static let spacesChangeIconParentTag = 500032
    static let spacesChangeThemeParentTag = 500033
    static let spacesNextItemTag = 500034
    static let spacesPreviousItemTag = 500035
    static let spacesChangeProfileParentTag = 500036
    static let spacesDeleteSpaceItemTag = 500037
    static let spacesListItemTagBase = 510000
    static let spacesURLRulesItemTag = 500021
    static let spacesURLRulesSeparatorTag = 500022
    static let spacesMenuIdentifier = NSUserInterfaceItemIdentifier("phi.spaces.menu")
    static let timeMachineBackupsMenuIdentifier = NSUserInterfaceItemIdentifier("phi.time-machine.backups.menu")
    
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

        var hasBookmarksMenu = false
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
                    item.tag == AppController.layoutModeTitleItemTag ||
                    item.tag == AppController.viewMenuSpacesToggleItemTag ||
                    item.tag == AppController.viewMenuSpacesToggleSeparatorTag
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

                let newConversationItem = NSMenuItem(title: NSLocalizedString("New Conversation", comment: "View menu - Menu item to start a new AI conversation in the sidebar"),
                                                   action: #selector(newConversation(_:)),
                                                   keyEquivalent: "o")
                newConversationItem.keyEquivalentModifierMask = [.command, .shift]
                newConversationItem.tag = CommandWrapper.PHI_NEW_CONVERSATION.rawValue
                Shortcuts.updateShortcut(for: newConversationItem)
                newConversationItem.target = self
                submenu.addItem(newConversationItem)

                let spacesToggleSeparator = NSMenuItem.separator()
                spacesToggleSeparator.tag = AppController.viewMenuSpacesToggleSeparatorTag
                submenu.addItem(spacesToggleSeparator)

                let spacesToggleItem = NSMenuItem(
                    title: NSLocalizedString("Enable Spaces", comment: "View menu - Master toggle for the Spaces feature"),
                    action: #selector(toggleSpacesFeature(_:)),
                    keyEquivalent: ""
                )
                spacesToggleItem.tag = AppController.viewMenuSpacesToggleItemTag
                spacesToggleItem.target = self
                submenu.addItem(spacesToggleItem)
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
            }

            switch BookmarkMainMenuItemRouting.action(title: menuItem.title, tag: menuItem.tag) {
            case .configureCustomItem:
                hasBookmarksMenu = true
                configureBookmarksMenuItem(menuItem)
            case .hideSystemItem:
                menuItem.isHidden = true
            case .ignore:
                break
            }

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
                    $0.tag == AppController.exportLogsItemTag ||
                    $0.tag == AppController.whatsNewItemTag ||
                    $0.tag == AppController.manageUserDataHelpSeparatorTag ||
                    $0.tag == AppController.timeMachineBackupsParentItemTag ||
                    $0.tag == AppController.manageUserDataParentItemTag
                }
                
                let extensionInfoItem = NSMenuItem(title: NSLocalizedString("Extension Info", comment: "Help menu - Menu item to show extension version info, only visible when holding Option key"),
                                                   action: #selector(showExtensionInfo(_:)),
                                                   keyEquivalent: "")
                extensionInfoItem.tag = AppController.extensionInfoItemTag
                extensionInfoItem.isHidden = true
                extensionInfoItem.target = self

                let exportLogsItem = NSMenuItem(title: NSLocalizedString("Export Logs...", comment: "Help menu - Menu item to export Phi and Sentinel logs as a zip archive; visible only when holding Option key"),
                                                action: #selector(exportLogs(_:)),
                                                keyEquivalent: "")
                exportLogsItem.tag = AppController.exportLogsItemTag
                exportLogsItem.isHidden = true
                exportLogsItem.target = self
                
                if subMenu.items.count > 0 {
                    subMenu.insertItem(extensionInfoItem, at: 0)
                    subMenu.insertItem(exportLogsItem, at: 1)
                } else {
                    subMenu.addItem(extensionInfoItem)
                    subMenu.addItem(exportLogsItem)
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

                let userDataSeparator = NSMenuItem.separator()
                userDataSeparator.tag = AppController.manageUserDataHelpSeparatorTag
                subMenu.addItem(userDataSeparator)

                subMenu.addItem(makeTimeMachineBackupsMenuItem())

                let manageUserDataTitle = NSLocalizedString("Manage User Data", comment: "Help menu - Parent menu item for exporting and importing Phi user data backup")
                let manageUserDataItem = NSMenuItem(title: manageUserDataTitle, action: nil, keyEquivalent: "")
                manageUserDataItem.tag = AppController.manageUserDataParentItemTag
                let userDataSubmenu = NSMenu(title: manageUserDataTitle)
                let exportUserDataItem = NSMenuItem(
                    title: NSLocalizedString("Export User Data...", comment: "Help menu - Submenu item to save Phi user data folder as a zip backup"),
                    action: #selector(exportUserData(_:)),
                    keyEquivalent: ""
                )
                exportUserDataItem.target = self
                let importUserDataItem = NSMenuItem(
                    title: NSLocalizedString("Import User Data...", comment: "Help menu - Submenu item to replace Phi user data from a zip backup and relaunch the app"),
                    action: #selector(importUserDataFromBackup(_:)),
                    keyEquivalent: ""
                )
                importUserDataItem.target = self
                userDataSubmenu.addItem(exportUserDataItem)
                userDataSubmenu.addItem(importUserDataItem)
                manageUserDataItem.submenu = userDataSubmenu
                subMenu.addItem(manageUserDataItem)
                
                subMenu.delegate = self
            }
        }

        if !hasBookmarksMenu {
            installBookmarksMenu(in: mainMenu)
        }

        installOrUpdateSpacesMenu(in: mainMenu)

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

    fileprivate func rebuildDeleteProfileSubmenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let deletable = ProfileManager.shared.profiles.filter { $0.profileId != LocalStore.defaultProfileId }
        guard !deletable.isEmpty else {
            let empty = NSMenuItem(
                title: NSLocalizedString("No Profiles to Delete", comment: "Spaces menu - Delete Profile submenu empty state"),
                action: nil,
                keyEquivalent: ""
            )
            menu.addItem(empty)
            return
        }
        let boundProfileIds = Set(SpaceManager.shared.spaces.map { $0.profileId })
        for profile in deletable {
            let inUse = boundProfileIds.contains(profile.profileId)
            let title: String
            if inUse {
                title = String(
                    format: NSLocalizedString("%@ — in use by a Space", comment: "Spaces menu - Delete Profile row label for a profile bound to a Space"),
                    profile.displayName
                )
            } else {
                title = profile.displayName
            }
            let item = NSMenuItem(
                title: title,
                action: #selector(deleteSelectedProfile(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = profile
            menu.addItem(item)
        }
    }

    @objc func newProfile(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("New Profile", comment: "Title of the create-profile dialog")
        alert.informativeText = NSLocalizedString(
            "Enter a name for the new profile. Each profile has its own cookies, history, and extensions.",
            comment: "Body of the create-profile dialog")
        alert.addButton(withTitle: NSLocalizedString("Create", comment: "Create button"))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Cancel button"))
        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        textField.placeholderString = NSLocalizedString("Profile name", comment: "Placeholder for the profile-name field")
        alert.accessoryView = textField
        DispatchQueue.main.async {
            textField.window?.makeFirstResponder(textField)
        }
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let trimmed = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        ProfileManager.shared.createProfile(displayName: trimmed) { _ in }
    }

    @objc func deleteSelectedProfile(_ sender: Any?) {
        guard let menuItem = sender as? NSMenuItem,
              let profile = menuItem.representedObject as? PhiBrowserProfile else {
            return
        }
        let alert = NSAlert()
        alert.messageText = String(
            format: NSLocalizedString("Delete profile \u{201C}%@\u{201D}?", comment: "Title of the delete-profile confirmation"),
            profile.displayName
        )
        alert.informativeText = NSLocalizedString(
            "All cookies, history, extensions, and saved data on this profile will be permanently removed. This cannot be undone.",
            comment: "Body of the delete-profile confirmation"
        )
        alert.alertStyle = .warning
        alert.addButton(withTitle: NSLocalizedString("Delete", comment: "Destructive button"))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Cancel button"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        ProfileManager.shared.deleteProfile(profile.profileId) { success, error in
            if !success {
                let errAlert = NSAlert()
                errAlert.messageText = NSLocalizedString("Couldn't delete profile", comment: "Title of the profile-delete error")
                errAlert.informativeText = error ?? NSLocalizedString("Unknown error", comment: "Fallback profile-delete error reason")
                errAlert.runModal()
            }
        }
    }

    private func configureBookmarksMenuItem(_ menuItem: NSMenuItem) {
        menuItem.title = NSLocalizedString("Bookmarks", comment: "Main menu - Top-level Bookmarks menu title in the application menu bar")
        menuItem.tag = AppController.bookmarksMenuItemTag
        menuItem.isHidden = false

        let submenu = menuItem.submenu ?? NSMenu(title: menuItem.title)
        submenu.identifier = AppController.bookmarksMenuIdentifier
        submenu.delegate = self
        menuItem.submenu = submenu

        rebuildBookmarksMenu(submenu)
    }

    private func installBookmarksMenu(in mainMenu: NSMenu) {
        let menuItem = NSMenuItem(
            title: NSLocalizedString("Bookmarks", comment: "Main menu - Top-level Bookmarks menu title in the application menu bar"),
            action: nil,
            keyEquivalent: ""
        )
        menuItem.tag = AppController.bookmarksMenuItemTag
        configureBookmarksMenuItem(menuItem)

        if let historyIndex = mainMenu.items.firstIndex(where: { $0.title == "History" }) {
            mainMenu.insertItem(menuItem, at: historyIndex + 1)
        } else if let windowIndex = mainMenu.items.firstIndex(where: { $0.title == "Window" }) {
            mainMenu.insertItem(menuItem, at: windowIndex)
        } else {
            mainMenu.addItem(menuItem)
        }
    }

    private func makeTimeMachineBackupsMenuItem() -> NSMenuItem {
        let title = NSLocalizedString("Time Machine Backups", comment: "Help menu - Parent menu item listing completed Phi Time Machine backups")
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.tag = AppController.timeMachineBackupsParentItemTag

        let submenu = NSMenu(title: title)
        submenu.identifier = AppController.timeMachineBackupsMenuIdentifier
        submenu.delegate = self
        rebuildTimeMachineBackupsMenu(submenu)
        item.submenu = submenu
        return item
    }

    private func rebuildTimeMachineBackupsMenu(_ menu: NSMenu) {
        do {
            try TimeMachineMenuPresenter().populate(
                menu,
                target: self,
                action: #selector(restoreTimeMachineBackup(_:))
            )
        } catch {
            AppLogError("Time Machine backups menu failed: \(error.localizedDescription)")
            menu.removeAllItems()
            let item = NSMenuItem(
                title: NSLocalizedString("Backups Unavailable", comment: "Help menu - Time Machine submenu placeholder when the backup catalog cannot be read"),
                action: nil,
                keyEquivalent: ""
            )
            item.isEnabled = false
            menu.addItem(item)
        }
    }

    private func rebuildBookmarksMenu(_ menu: NSMenu) {
        let bookmarks = MainBrowserWindowControllersManager.shared.activeWindowController?.browserState.bookmarkManager.rootFolder.children ?? []

        BookmarkMenuContentBuilder.populate(
            menu: menu,
            bookmarks: bookmarks,
            canBookmarkCurrentTab: canBookmarkCurrentTab(),
            canBookmarkAllTabs: canBookmarkAllTabs(),
            target: self,
            bookmarkThisTabAction: #selector(bookmarkThisTab(_:)),
            bookmarkAllTabsAction: #selector(bookmarkAllTabs(_:)),
            openBookmarkAction: #selector(openBookmarkMenuItem(_:))
        )
    }

    private func isActiveWindowIncognito() -> Bool {
        MainBrowserWindowControllersManager.shared.activeWindowController?.browserState.isIncognito == true
    }

    private func canBookmarkCurrentTab() -> Bool {
        guard !isActiveWindowIncognito() else { return false }
        guard let state = MainBrowserWindowControllersManager.shared
            .activeWindowController?.browserState,
              !state.isInPlaceholderMode,
              let tab = state.focusingTab,
              let url = tab.url, !url.isEmpty else {
            return false
        }

        return true
    }

    private func canBookmarkAllTabs() -> Bool {
        guard !isActiveWindowIncognito() else { return false }
        let bookmarkableTabsCount = MainBrowserWindowControllersManager.shared.activeWindowController?.browserState.normalTabs.filter { !$0.isLocalPage }.count ?? 0
        return bookmarkableTabsCount > 1
    }
    
    @objc func toggleSidebar(_ sender: Any?) {
        MainBrowserWindowControllersManager.shared.activeWindowController?.browserState.toggleSidebar()
    }
    
    @objc func toggleChatbar(_ sendar: Any?) {
        MainBrowserWindowControllersManager.shared.activeWindowController?.browserState.toggleAIChat()
    }

    /// Starts a new AI conversation in the focused tab's sidebar.
    ///
    /// The actual "new conversation" logic lives inside the Sidecar extension
    /// (React), so we can't run it natively. Instead we broadcast a message the
    /// extension listens for. Validation (`validateUserInterfaceItem`) already
    /// guarantees focus is inside the AI sidebar when this fires, so the sidebar
    /// is open and visible — no need to open it here.
    ///
    /// Each browser tab has its own AI sidebar WebContents (one Sidecar instance
    /// per tab), and they all share the same `windowId`. So we carry the focused
    /// tab's `tabId` (its Chromium `guid`, the same value embedded as `?tabId=`
    /// when the sidebar is created) to let exactly that tab's Sidecar respond.
    @MainActor
    @objc func newConversation(_ sender: Any?) {
        guard let windowController = MainBrowserWindowControllersManager.shared.activeWindowController,
              let tabId = windowController.browserState.focusingTab?.guid else {
            return
        }
        let payload: [String: Any] = ["tabId": tabId]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else {
            return
        }
        ExtensionMessaging.shared.broadcast(type: "newConversation", payload: json)
    }

    @objc func toggleBookmarkBar(_ sender: Any?) {
        let currentValue = PhiPreferences.GeneralSettings.alwaysShowBookmarkBar.loadValue()
        UserDefaults.standard.set(!currentValue, forKey: PhiPreferences.GeneralSettings.alwaysShowBookmarkBar.rawValue)
    }

    @objc func toggleBookmarkBarOnNewTab(_ sender: Any?) {
        let currentValue = PhiPreferences.GeneralSettings.showBookmarkBarOnNewTabPage.loadValue()
        UserDefaults.standard.set(!currentValue, forKey: PhiPreferences.GeneralSettings.showBookmarkBarOnNewTabPage.rawValue)
    }

    @objc func bookmarkThisTab(_ sender: Any?) {
        MainBrowserWindowControllersManager.shared.activeWindowController?.toggleBookmark(sender)
    }

    @objc func bookmarkAllTabs(_ sender: Any?) {
        guard let state = MainBrowserWindowControllersManager.shared.activeWindowController?.browserState else {
            return
        }

        let tabs = state.normalTabs
        guard !tabs.isEmpty else { return }
        for tab in tabs {
            if tab.isLocalPage { continue }
            let title = tab.title.isEmpty ? (tab.url ?? "") : tab.title
            let url = tab.url ?? ""
            guard !url.isEmpty else { continue }
            state.bookmarkManager.addBookmark(title: title, url: url)
        }
    }

    @objc func openBookmarkMenuItem(_ sender: Any?) {
        guard let item = sender as? NSMenuItem,
              let bookmark = item.representedObject as? Bookmark else {
            return
        }

        MainBrowserWindowControllersManager.shared.activeWindowController?.browserState.openBookmark(bookmark)
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

    @objc func toggleSpacesFeature(_ sender: Any?) {
        let enabled = PhiPreferences.GeneralSettings.spacesFeatureEnabled.loadValue()
        SpaceManager.shared.setFeatureEnabled(!enabled)
        updateSpacesMenuVisibility()
    }

    /// Toggles the Spaces top-level menu item's visibility to match the
    /// current feature flag. Called right after `toggleSpacesFeature` flips
    /// the preference so the menu bar reflects the new state without waiting
    /// for the next main-menu rebuild.
    private func updateSpacesMenuVisibility() {
        guard let mainMenu = NSApp.mainMenu else { return }
        let enabled = PhiPreferences.GeneralSettings.spacesFeatureEnabled.loadValue()
        mainMenu.item(withTag: AppController.spacesMenuItemTag)?.isHidden = !enabled
    }
    
    @objc func showWhatsNew(_ sender: Any?) {
        BrowserState.currentState()?.createTab("chrome://whats-new", focusAfterCreate: true)
    }

    @objc func restoreTimeMachineBackup(_ sender: Any?) {
        guard let menuItem = sender as? NSMenuItem,
              let backupIDString = menuItem.representedObject as? String,
              let backupID = UUID(uuidString: backupIDString) else {
            return
        }

        do {
            guard let backup = try TimeMachineMenuPresenter().backup(id: backupID) else {
                presentTimeMachineRestoreFailure(
                    NSLocalizedString("The selected Time Machine backup is no longer available.", comment: "Help menu - Time Machine restore error when a selected backup disappears")
                )
                return
            }

            let backupTitle = backup.menuTitle()
            let alert = NSAlert()
            alert.messageText = NSLocalizedString("Restore Time Machine Backup?", comment: "Help menu - Time Machine restore confirmation title")
            let messageTemplate = NSLocalizedString(
                "Phi will quit and restore %@. The current app and selected user data will be replaced.",
                comment: "Help menu - Time Machine restore confirmation body"
            )
            alert.informativeText = String(format: messageTemplate, backupTitle)
            alert.alertStyle = .warning
            alert.addButton(withTitle: NSLocalizedString("Restore", comment: "Help menu - Time Machine restore confirmation button"))
            alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Generic - Cancel button to dismiss an alert"))

            guard alert.runModal() == .alertFirstButtonReturn else {
                return
            }

            let progressModal = TimeMachineRestoreProgressModal(backupTitle: backupTitle)
            DispatchQueue.main.async {
                Task {
                    let coordinator = TimeMachineRestoreCoordinator(progressHandler: { progress in
                        Task { @MainActor in
                            progressModal.update(progress)
                        }
                    })

                    do {
                        _ = try await coordinator.prepareAndLaunchRestore(for: backup)
                        await MainActor.run {
                            progressModal.finish(outcome: .success(()), response: .OK)
                        }
                    } catch {
                        await MainActor.run {
                            progressModal.finish(outcome: .failure(error), response: .abort)
                        }
                    }
                }
            }

            _ = progressModal.run()
            switch progressModal.outcome {
            case .some(.success):
                NSApp.terminate(nil)
            case .some(.failure(let error)):
                let messageTemplate = NSLocalizedString(
                    "Phi could not start Time Machine restore: %@",
                    comment: "Help menu - Time Machine restore launch failure body"
                )
                presentTimeMachineRestoreFailure(String(format: messageTemplate, error.localizedDescription))
            case .none:
                break
            }
        } catch {
            let messageTemplate = NSLocalizedString(
                "Phi could not read Time Machine backups: %@",
                comment: "Help menu - Time Machine restore catalog read failure body"
            )
            presentTimeMachineRestoreFailure(String(format: messageTemplate, error.localizedDescription))
        }
    }

    private func presentTimeMachineRestoreFailure(_ message: String) {
        AppLogError("Time Machine restore failed: \(message)")
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Time Machine Restore Failed", comment: "Help menu - Time Machine restore failure alert title")
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: NSLocalizedString("OK", comment: "Generic - OK button to dismiss an alert"))
        alert.runModal()
    }
    
    @objc func exportLogs(_ sender: Any?) {
        let phiLogsURL = URL(fileURLWithPath: FileSystemUtils.phiBrowserDataDirectory(), isDirectory: true)
            .appendingPathComponent("PhiLogs", isDirectory: true)
        let sentinelLogsURL = SentinelHelper.sentinelLogsDirectoryURL()
        let fm = FileManager.default
        let hasPhi = fm.fileExists(atPath: phiLogsURL.path)
        let hasSentinel = fm.fileExists(atPath: sentinelLogsURL.path)
        guard hasPhi || hasSentinel else {
            let alert = NSAlert()
            alert.messageText = NSLocalizedString("Export Logs", comment: "Help menu - Log export alert title when no log folders exist")
            alert.informativeText = NSLocalizedString("No Phi or Sentinel log folders were found.", comment: "Help menu - Log export alert when both PhiLogs and Sentinel log directory are missing")
            alert.alertStyle = .informational
            alert.addButton(withTitle: NSLocalizedString("OK", comment: "Generic - OK button to dismiss an alert"))
            alert.runModal()
            return
        }

        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.zip]
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        panel.nameFieldStringValue = "Phi_Logs_\(formatter.string(from: Date())).zip"
        panel.title = NSLocalizedString("Export Logs", comment: "Help menu - NSSavePanel window title for saving the log export zip")
        panel.prompt = NSLocalizedString("Export", comment: "Help menu - NSSavePanel primary button title for confirming log export save location")

        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self, response == .OK, let destURL = panel.url else { return }
            do {
                try self.zipPhiLogsExport(
                    phiLogsURL: phiLogsURL,
                    sentinelLogsURL: sentinelLogsURL,
                    includePhi: hasPhi,
                    includeSentinel: hasSentinel,
                    destinationZIP: destURL
                )
            } catch {
                AppLogError("Log export failed: \(error.localizedDescription)")
                let alert = NSAlert()
                alert.messageText = NSLocalizedString("Export Failed", comment: "Help menu - Log export error alert title")
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                alert.addButton(withTitle: NSLocalizedString("OK", comment: "Generic - OK button to dismiss an alert"))
                alert.runModal()
            }
        }

        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(panel.runModal())
        }
    }

    private func zipPhiLogsExport(
        phiLogsURL: URL,
        sentinelLogsURL: URL,
        includePhi: Bool,
        includeSentinel: Bool,
        destinationZIP: URL
    ) throws {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("PhiLogExport-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        var zipRoots: [String] = []
        if includePhi {
            let dest = staging.appendingPathComponent("PhiLogs", isDirectory: true)
            try fm.copyItem(at: phiLogsURL, to: dest)
            zipRoots.append("PhiLogs")
        }
        if includeSentinel {
            let dest = staging.appendingPathComponent("SentinelLogs", isDirectory: true)
            try fm.copyItem(at: sentinelLogsURL, to: dest)
            zipRoots.append("SentinelLogs")
        }
        guard !zipRoots.isEmpty else { return }

        if fm.fileExists(atPath: destinationZIP.path) {
            try fm.removeItem(at: destinationZIP)
        }

        let stderrPipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-r", "-q", destinationZIP.path] + zipRoots
        process.currentDirectoryURL = staging
        process.standardError = stderrPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let errText = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let detail = errText.isEmpty ? "zip exited with status \(process.terminationStatus)." : errText
            throw NSError(domain: "PhiLogExport", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: detail])
        }
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

    // MARK: - Spaces top-level menu

    /// Finds the existing Spaces top-level menu item by tag and refreshes its
    /// submenu, or installs a new one right after the View menu when this is
    /// the first time the main menu has been hooked (or after Chromium swapped
    /// the menu wholesale).
    private func installOrUpdateSpacesMenu(in mainMenu: NSMenu) {
        let menuItem: NSMenuItem
        let isNew: Bool
        if let existing = mainMenu.items.first(where: { $0.tag == AppController.spacesMenuItemTag }) {
            menuItem = existing
            isNew = false
        } else {
            menuItem = NSMenuItem(
                title: NSLocalizedString("Spaces", comment: "Main menu - Top-level Spaces menu title in the application menu bar"),
                action: nil,
                keyEquivalent: ""
            )
            menuItem.tag = AppController.spacesMenuItemTag
            isNew = true
        }

        let submenu = menuItem.submenu ?? NSMenu(title: menuItem.title)
        submenu.identifier = AppController.spacesMenuIdentifier
        submenu.delegate = self
        submenu.autoenablesItems = true
        menuItem.submenu = submenu
        menuItem.isHidden = !PhiPreferences.GeneralSettings.spacesFeatureEnabled.loadValue()

        rebuildSpacesMenu(submenu)

        if isNew {
            let insertIndex: Int
            if let viewIdx = mainMenu.items.firstIndex(where: { $0.title == "View" }) {
                insertIndex = viewIdx + 1
            } else if let historyIdx = mainMenu.items.firstIndex(where: { $0.title == "History" }) {
                insertIndex = historyIdx
            } else {
                insertIndex = mainMenu.items.count
            }
            mainMenu.insertItem(menuItem, at: insertIndex)
        }
    }

    /// Populates the Spaces submenu from `SpaceManager.shared`. Called from
    /// `installOrUpdateSpacesMenu` after a main-menu swap and from
    /// `menuWillOpen` so each open reflects the current Spaces list and the
    /// active Space of the focused window.
    /// Appends the active-Space actions (Rename, Change Icon, Edit Theme,
    /// Change Profile) to `menu`, so other context menus — e.g. the sidebar /
    /// tab-area menu — can offer the same Space controls as the Spaces menu.
    /// Items target the controller and act on the currently active Space.
    func appendActiveSpaceMenuItems(to menu: NSMenu) {
        let activeSpace = currentActiveSpace()

        let newSpaceItem = NSMenuItem(
            title: NSLocalizedString("New Space\u{2026}", comment: "Spaces menu - Create a new Space"),
            action: #selector(newSpaceFromMenu(_:)),
            keyEquivalent: ""
        )
        newSpaceItem.target = self
        menu.addItem(newSpaceItem)

        let renameItem = NSMenuItem(
            title: NSLocalizedString("Rename Space\u{2026}", comment: "Spaces menu - Rename the active Space"),
            action: #selector(renameActiveSpace(_:)),
            keyEquivalent: ""
        )
        renameItem.target = self
        menu.addItem(renameItem)

        let changeIconParent = NSMenuItem(
            title: NSLocalizedString("Change Icon", comment: "Spaces menu - Submenu to change the active Space's icon"),
            action: nil,
            keyEquivalent: ""
        )
        changeIconParent.submenu = makeSpacesIconSubmenu(for: activeSpace)
        menu.addItem(changeIconParent)

        let editThemeParent = NSMenuItem(
            title: NSLocalizedString("Edit Theme", comment: "Spaces menu - Submenu to set a theme override for the active Space"),
            action: nil,
            keyEquivalent: ""
        )
        editThemeParent.submenu = makeSpacesThemeSubmenu(for: activeSpace?.spaceId)
        menu.addItem(editThemeParent)

        let changeProfileParent = NSMenuItem(
            title: NSLocalizedString("Change Profile", comment: "Spaces menu - Submenu to re-bind the active Space to another profile"),
            action: nil,
            keyEquivalent: ""
        )
        changeProfileParent.submenu = makeSpacesProfileSubmenu(for: activeSpace)
        menu.addItem(changeProfileParent)

        let deleteSpaceItem = NSMenuItem(
            title: NSLocalizedString("Delete Space\u{2026}", comment: "Spaces menu - Delete the active Space"),
            action: #selector(deleteActiveSpace(_:)),
            keyEquivalent: ""
        )
        deleteSpaceItem.target = self
        menu.addItem(deleteSpaceItem)
    }

    fileprivate func rebuildSpacesMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let activeSpace = currentActiveSpace()
        let activeSpaceId = activeSpace?.spaceId

        let newSpaceItem = NSMenuItem(
            title: NSLocalizedString("New Space\u{2026}", comment: "Spaces menu - Create a new Space"),
            action: #selector(newSpaceFromMenu(_:)),
            keyEquivalent: ""
        )
        newSpaceItem.tag = AppController.spacesNewSpaceItemTag
        newSpaceItem.target = self
        menu.addItem(newSpaceItem)

        let renameItem = NSMenuItem(
            title: NSLocalizedString("Rename Space\u{2026}", comment: "Spaces menu - Rename the active Space"),
            action: #selector(renameActiveSpace(_:)),
            keyEquivalent: ""
        )
        renameItem.tag = AppController.spacesRenameItemTag
        renameItem.target = self
        menu.addItem(renameItem)

        let changeIconParent = NSMenuItem(
            title: NSLocalizedString("Change Icon", comment: "Spaces menu - Submenu to change the active Space's icon"),
            action: nil,
            keyEquivalent: ""
        )
        changeIconParent.tag = AppController.spacesChangeIconParentTag
        changeIconParent.submenu = makeSpacesIconSubmenu(for: activeSpace)
        menu.addItem(changeIconParent)

        let editThemeParent = NSMenuItem(
            title: NSLocalizedString("Edit Theme", comment: "Spaces menu - Submenu to set a theme override for the active Space"),
            action: nil,
            keyEquivalent: ""
        )
        editThemeParent.tag = AppController.spacesChangeThemeParentTag
        editThemeParent.submenu = makeSpacesThemeSubmenu(for: activeSpaceId)
        menu.addItem(editThemeParent)

        let changeProfileParent = NSMenuItem(
            title: NSLocalizedString("Change Profile", comment: "Spaces menu - Submenu to re-bind the active Space to another profile"),
            action: nil,
            keyEquivalent: ""
        )
        changeProfileParent.tag = AppController.spacesChangeProfileParentTag
        changeProfileParent.submenu = makeSpacesProfileSubmenu(for: activeSpace)
        menu.addItem(changeProfileParent)

        let deleteSpaceItem = NSMenuItem(
            title: NSLocalizedString("Delete Space\u{2026}", comment: "Spaces menu - Delete the active Space"),
            action: #selector(deleteActiveSpace(_:)),
            keyEquivalent: ""
        )
        deleteSpaceItem.tag = AppController.spacesDeleteSpaceItemTag
        deleteSpaceItem.target = self
        menu.addItem(deleteSpaceItem)

        menu.addItem(.separator())

        let nextItem = NSMenuItem(
            title: NSLocalizedString("Next Space", comment: "Spaces menu - Activate the next Space in the strip"),
            action: #selector(activateNextSpace(_:)),
            keyEquivalent: "\u{F703}"
        )
        nextItem.keyEquivalentModifierMask = [.command, .option]
        nextItem.tag = AppController.spacesNextItemTag
        nextItem.target = self
        menu.addItem(nextItem)

        let prevItem = NSMenuItem(
            title: NSLocalizedString("Previous Space", comment: "Spaces menu - Activate the previous Space in the strip"),
            action: #selector(activatePreviousSpace(_:)),
            keyEquivalent: "\u{F702}"
        )
        prevItem.keyEquivalentModifierMask = [.command, .option]
        prevItem.tag = AppController.spacesPreviousItemTag
        prevItem.target = self
        menu.addItem(prevItem)

        let spaces = SpaceManager.shared.spaces
        if !spaces.isEmpty {
            menu.addItem(.separator())
            for (index, space) in spaces.enumerated() {
                let item = NSMenuItem(
                    title: space.name,
                    action: #selector(activateSpaceFromMenu(_:)),
                    keyEquivalent: index < 9 ? "\(index + 1)" : ""
                )
                if index < 9 {
                    item.keyEquivalentModifierMask = [.control]
                }
                item.tag = AppController.spacesListItemTagBase + index
                item.target = self
                item.representedObject = space.spaceId
                item.state = (space.spaceId == activeSpaceId) ? .on : .off
                let symbol = space.iconName.isEmpty ? "rectangle.stack" : space.iconName
                item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
                menu.addItem(item)
            }
        }

        let urlRulesSeparator = NSMenuItem.separator()
        urlRulesSeparator.tag = AppController.spacesURLRulesSeparatorTag
        menu.addItem(urlRulesSeparator)

        let urlRulesItem = NSMenuItem(
            title: NSLocalizedString("URL Rules\u{2026}", comment: "Spaces menu - Open the universal URL routing rules editor"),
            action: #selector(openURLRulesEditor(_:)),
            keyEquivalent: ""
        )
        urlRulesItem.tag = AppController.spacesURLRulesItemTag
        urlRulesItem.target = self
        menu.addItem(urlRulesItem)

        let profileSeparator = NSMenuItem.separator()
        profileSeparator.tag = AppController.spacesProfileSeparatorTag
        menu.addItem(profileSeparator)

        let newProfileItem = NSMenuItem(
            title: NSLocalizedString("New Profile\u{2026}", comment: "Spaces menu - Create a new browser profile"),
            action: #selector(newProfile(_:)),
            keyEquivalent: ""
        )
        newProfileItem.tag = AppController.spacesNewProfileItemTag
        newProfileItem.target = self
        menu.addItem(newProfileItem)

        let deleteProfileTitle = NSLocalizedString("Delete Profile", comment: "Spaces menu - Submenu listing deletable browser profiles")
        let deleteProfileParent = NSMenuItem(
            title: deleteProfileTitle,
            action: nil,
            keyEquivalent: ""
        )
        deleteProfileParent.tag = AppController.spacesDeleteProfileParentItemTag
        let deleteSubmenu = NSMenu(title: deleteProfileTitle)
        deleteSubmenu.identifier = AppController.deleteProfileSubmenuIdentifier
        deleteSubmenu.delegate = self
        deleteProfileParent.submenu = deleteSubmenu
        menu.addItem(deleteProfileParent)
        rebuildDeleteProfileSubmenu(deleteSubmenu)
    }

    private func makeSpacesIconSubmenu(for space: SpaceModel?) -> NSMenu {
        let menu = NSMenu(title: NSLocalizedString("Change Icon", comment: "Spaces menu - Submenu to change the active Space's icon"))
        let activeIconName = space?.iconName
        for icon in SpacesStripView.iconOptions {
            let item = NSMenuItem(
                title: prettySpaceIconLabel(icon),
                action: #selector(selectSpaceIcon(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = icon
            item.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)
            item.state = (icon == activeIconName) ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    private func makeSpacesThemeSubmenu(for spaceId: String?) -> NSMenu {
        let menu = NSMenu(title: NSLocalizedString("Edit Theme", comment: "Spaces menu - Submenu to set a theme override for the active Space"))
        let pinnedId = spaceId.flatMap { SpaceManager.shared.themeId(forSpaceId: $0) }

        let followGlobal = NSMenuItem(
            title: NSLocalizedString("Follow Global", comment: "Spaces menu - Theme submenu entry that clears the per-Space override"),
            action: #selector(selectSpaceTheme(_:)),
            keyEquivalent: ""
        )
        followGlobal.target = self
        followGlobal.representedObject = nil
        followGlobal.state = (pinnedId == nil) ? .on : .off
        menu.addItem(followGlobal)

        let themes = ThemeManager.shared.registeredThemes.values
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        if !themes.isEmpty {
            menu.addItem(.separator())
        }
        for theme in themes {
            let item = NSMenuItem(
                title: theme.name,
                action: #selector(selectSpaceTheme(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = theme.id
            item.state = (pinnedId == theme.id) ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    private func makeSpacesProfileSubmenu(for space: SpaceModel?) -> NSMenu {
        let menu = NSMenu(title: NSLocalizedString("Change Profile", comment: "Spaces menu - Submenu to re-bind the active Space to another profile"))
        for profile in ProfileManager.shared.profiles {
            let item = NSMenuItem(
                title: profile.displayName,
                action: #selector(selectSpaceProfile(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = profile.profileId
            item.state = (profile.profileId == space?.profileId) ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    private func prettySpaceIconLabel(_ id: String) -> String {
        id.split(separator: ".")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    /// Slot the menu actions should target. Prefers the controller that's
    /// currently active in this app instance; falls back to the `keySlot`
    /// (most-recently-key window) when no controller is active — covers the
    /// menu-bar-from-background-app case.
    fileprivate func currentSpacesSlot() -> SpaceWindowSlot? {
        MainBrowserWindowControllersManager.shared.activeWindowController?.slot
            ?? SpaceManager.shared.keySlot
    }

    fileprivate func currentActiveSpace() -> SpaceModel? {
        let slot = currentSpacesSlot()
        let id = slot?.activeSpaceId ?? SpaceManager.shared.activeSpaceId
        guard let id else { return nil }
        return SpaceManager.shared.spaces.first(where: { $0.spaceId == id })
    }

    private func cycleActiveSpace(by step: Int) {
        let spaces = SpaceManager.shared.spaces
        guard !spaces.isEmpty, let slot = currentSpacesSlot() else { return }
        guard let currentId = slot.activeSpaceId,
              let currentIdx = spaces.firstIndex(where: { $0.spaceId == currentId }) else {
            slot.activate(spaceId: spaces[0].spaceId)
            return
        }
        let nextIdx = (currentIdx + step + spaces.count) % spaces.count
        slot.activate(spaceId: spaces[nextIdx].spaceId)
    }

    @objc func newSpaceFromMenu(_ sender: Any?) {
        let activeProfileId = currentActiveSpace()?.profileId ?? LocalStore.defaultProfileId
        CreateSpacePanel.requestCreation(initialProfileId: activeProfileId)
    }

    @objc func renameActiveSpace(_ sender: Any?) {
        guard let space = currentActiveSpace() else { return }
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Rename Space", comment: "Title of the rename-Space dialog")
        alert.informativeText = NSLocalizedString("Enter a new name for this Space.", comment: "Body of the rename-Space dialog")
        alert.addButton(withTitle: NSLocalizedString("Rename", comment: "Rename button"))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Cancel button"))
        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        textField.stringValue = space.name
        textField.placeholderString = space.name
        alert.accessoryView = textField
        DispatchQueue.main.async {
            textField.window?.makeFirstResponder(textField)
            textField.selectText(nil)
        }
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let trimmed = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != space.name else { return }
        SpaceManager.shared.renameSpace(spaceId: space.spaceId, to: trimmed)
    }

    @objc func selectSpaceIcon(_ sender: Any?) {
        guard let menuItem = sender as? NSMenuItem,
              let iconName = menuItem.representedObject as? String,
              let space = currentActiveSpace() else { return }
        SpaceManager.shared.changeIcon(spaceId: space.spaceId, iconName: iconName)
    }

    @objc func selectSpaceTheme(_ sender: Any?) {
        guard let menuItem = sender as? NSMenuItem,
              let space = currentActiveSpace() else { return }
        let themeId = menuItem.representedObject as? String
        SpaceManager.shared.setTheme(forSpaceId: space.spaceId, themeId: themeId)
    }

    @objc func selectSpaceProfile(_ sender: Any?) {
        guard let menuItem = sender as? NSMenuItem,
              let profileId = menuItem.representedObject as? String,
              let space = currentActiveSpace(),
              space.spaceId != LocalStore.defaultSpaceId,
              space.profileId != profileId,
              let profile = ProfileManager.shared.profile(for: profileId) else { return }
        // Changing the profile closes and respawns the Space's window (a
        // window's profile is baked in at spawn); its open tabs are
        // reopened on the new profile — confirm like Space deletion does.
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            format: NSLocalizedString("Change Profile to \u{201C}%@\u{201D}?", comment: "Title of the change-Space-profile confirmation"),
            profile.displayName
        )
        alert.informativeText = NSLocalizedString(
            "This Space's window will be reopened with the new profile and its open tabs will be reloaded there. Site logins won't carry over. Bookmarks stay with the Space; pinned tabs will be the new profile's.",
            comment: "Body of the change-Space-profile confirmation"
        )
        alert.addButton(withTitle: NSLocalizedString("Change Profile", comment: "Confirm button of the change-Space-profile confirmation"))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Cancel button"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        SpaceManager.shared.changeProfile(spaceId: space.spaceId, toProfileId: profileId)
    }

    @objc func deleteActiveSpace(_ sender: Any?) {
        guard let space = currentActiveSpace(),
              space.spaceId != LocalStore.defaultSpaceId else { return }
        let alert = NSAlert()
        alert.messageText = String(
            format: NSLocalizedString("Delete \u{201C}%@\u{201D}?", comment: "Title of the delete-Space confirmation"),
            space.name
        )
        alert.informativeText = NSLocalizedString(
            "Pinned tabs and bookmarks belonging to this Space will also be removed. This action cannot be undone.",
            comment: "Body of the delete-Space confirmation"
        )
        alert.alertStyle = .warning
        alert.addButton(withTitle: NSLocalizedString("Delete", comment: "Destructive button"))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Cancel button"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        SpaceManager.shared.deleteSpace(spaceId: space.spaceId)
    }

    @objc func activateNextSpace(_ sender: Any?) {
        cycleActiveSpace(by: 1)
    }

    @objc func activatePreviousSpace(_ sender: Any?) {
        cycleActiveSpace(by: -1)
    }

    @objc func activateSpaceFromMenu(_ sender: Any?) {
        guard let menuItem = sender as? NSMenuItem,
              let spaceId = menuItem.representedObject as? String,
              let slot = currentSpacesSlot() else { return }
        slot.activate(spaceId: spaceId)
    }

    @objc func openURLRulesEditor(_ sender: Any?) {
        if let existing = NSApp.windows.first(where: { $0.identifier?.rawValue == "Phi URL Rules" }) {
            existing.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier("Phi URL Rules")
        window.title = NSLocalizedString("URL Rules", comment: "Window title for the universal URL rules editor")
        window.isReleasedWhenClosed = false
        let editor = URLRulesEditor(manager: SpaceManager.shared) { [weak window] in
            window?.close()
        }
        window.contentViewController = ThemedHostingController(rootView: editor)
        window.setContentSize(NSSize(width: 680, height: 460))
        window.center()
        window.makeKeyAndOrderFront(nil)
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
        // Placeholder mode: tab-targeted menu items must not act on the
        // (now-empty) tab strip. Chromium-side CommandUpdater already disables
        // most of these because the placeholder isn't in TabStripModel; this
        // is belt-and-suspenders for selector-based items (AI sidebar) and
        // defensive against any Chromium command that might still trip.
        if MainBrowserWindowControllersManager.shared
            .getActiveWindowState()?.isInPlaceholderMode == true {
            if item.action == #selector(toggleChatbar(_:)) { return false }
            if let menuItem = item as? NSMenuItem {
                let placeholderDisabledTags: Set<Int> = [
                    CommandWrapper.IDC_RELOAD.rawValue,
                    CommandWrapper.IDC_RELOAD_BYPASSING_CACHE.rawValue,
                    33009,                                       // IDC_RELOAD_CLEARING_CACHE
                    CommandWrapper.IDC_CLOSE_TAB.rawValue,
                    CommandWrapper.IDC_VIEW_SOURCE.rawValue,
                    CommandWrapper.IDC_DEV_TOOLS.rawValue,
                    CommandWrapper.IDC_DEV_TOOLS_INSPECT.rawValue,
                    CommandWrapper.IDC_DEV_TOOLS_CONSOLE.rawValue,
                    40007,                                       // IDC_DEV_TOOLS_DEVICES
                    40237,                                       // IDC_DEV_TOOLS_TOGGLE
                    CommandWrapper.IDC_FIND.rawValue,
                    CommandWrapper.IDC_FIND_NEXT.rawValue,
                    CommandWrapper.IDC_FIND_PREVIOUS.rawValue,
                    CommandWrapper.IDC_PRINT.rawValue,
                    CommandWrapper.IDC_ZOOM_PLUS.rawValue,
                    CommandWrapper.IDC_ZOOM_MINUS.rawValue,
                    CommandWrapper.IDC_ZOOM_NORMAL.rawValue,
                    CommandWrapper.IDC_SAVE_PAGE.rawValue,
                    CommandWrapper.IDC_BACK.rawValue,
                    CommandWrapper.IDC_FORWARD.rawValue,
                ]
                if placeholderDisabledTags.contains(menuItem.tag) { return false }
            }
        }

        if item.action == #selector(toggleChatbar(_:)) {
            let phiAIEnabled = UserDefaults.standard.bool(forKey: PhiPreferences.AISettings.phiAIEnabled.rawValue)
            let state = MainBrowserWindowControllersManager.shared.getActiveWindowState()
            if !phiAIEnabled || state?.isIncognito ?? false || state?.groupOverviewState != nil || state?.focusingTab?.aiChatEnabled == false {
                return false
            }
        }

        // New Conversation only applies while focus is inside the AI sidebar;
        // otherwise disable the item so its shortcut falls through to the
        // original behavior.
        if item.action == #selector(newConversation(_:)) {
            let phiAIEnabled = UserDefaults.standard.bool(forKey: PhiPreferences.AISettings.phiAIEnabled.rawValue)
            let state = MainBrowserWindowControllersManager.shared.getActiveWindowState()
            guard phiAIEnabled,
                  let state,
                  !state.isIncognito,
                  state.groupOverviewState == nil,
                  state.focusingTab?.aiChatEnabled == true,
                  state.focusingTab?.lastFocusTarget == .aiChat else {
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
        let spacesFeatureEnabled = PhiPreferences.GeneralSettings.spacesFeatureEnabled.loadValue()
        if item.action == #selector(toggleSpacesFeature(_:)) {
            if let menuItem = item as? NSMenuItem {
                menuItem.isHidden = false
                menuItem.state = spacesFeatureEnabled ? .on : .off
            }
            return LoginController.shared.isLoggedin()
        }
        if item.action == #selector(newProfile(_:)) {
            if let menuItem = item as? NSMenuItem {
                menuItem.isHidden = !spacesFeatureEnabled
            }
            return spacesFeatureEnabled && LoginController.shared.isLoggedin()
        }
        if item.action == #selector(deleteSelectedProfile(_:)) {
            guard spacesFeatureEnabled,
                  LoginController.shared.isLoggedin(),
                  let menuItem = item as? NSMenuItem,
                  let profile = menuItem.representedObject as? PhiBrowserProfile else {
                return false
            }
            return !SpaceManager.shared.spaces.contains(where: { $0.profileId == profile.profileId })
        }
        let spacesActions: [Selector] = [
            #selector(newSpaceFromMenu(_:)),
            #selector(renameActiveSpace(_:)),
            #selector(selectSpaceIcon(_:)),
            #selector(selectSpaceTheme(_:)),
            #selector(selectSpaceProfile(_:)),
            #selector(deleteActiveSpace(_:)),
            #selector(activateNextSpace(_:)),
            #selector(activatePreviousSpace(_:)),
            #selector(activateSpaceFromMenu(_:)),
            #selector(openURLRulesEditor(_:)),
        ]
        if let action = item.action, spacesActions.contains(action) {
            guard spacesFeatureEnabled, LoginController.shared.isLoggedin() else { return false }
            if action == #selector(renameActiveSpace(_:)) || action == #selector(selectSpaceIcon(_:)) {
                return currentActiveSpace() != nil
            }
            if action == #selector(deleteActiveSpace(_:)) {
                // The default Space can't be deleted — its bookmark root is
                // shared with the legacy per-profile root.
                guard let space = currentActiveSpace() else { return false }
                return space.spaceId != LocalStore.defaultSpaceId
            }
            if action == #selector(selectSpaceTheme(_:)) {
                guard currentActiveSpace() != nil else { return false }
                if let menuItem = item as? NSMenuItem {
                    let pinnedId = currentActiveSpace().flatMap {
                        SpaceManager.shared.themeId(forSpaceId: $0.spaceId)
                    }
                    let representedId = menuItem.representedObject as? String
                    menuItem.state = (pinnedId == representedId) ? .on : .off
                }
                return true
            }
            if action == #selector(selectSpaceProfile(_:)) {
                // The default space's profile can't change — its bookmark
                // root is shared with the legacy per-profile root.
                guard let space = currentActiveSpace(),
                      space.spaceId != LocalStore.defaultSpaceId else { return false }
                if let menuItem = item as? NSMenuItem {
                    let representedId = menuItem.representedObject as? String
                    menuItem.state = (representedId == space.profileId) ? .on : .off
                }
                return true
            }
            if action == #selector(activateNextSpace(_:)) || action == #selector(activatePreviousSpace(_:)) {
                return SpaceManager.shared.spaces.count > 1 && currentSpacesSlot() != nil
            }
            if action == #selector(activateSpaceFromMenu(_:)) {
                if let menuItem = item as? NSMenuItem,
                   let spaceId = menuItem.representedObject as? String {
                    let activeId = currentActiveSpace()?.spaceId
                    menuItem.state = (spaceId == activeId) ? .on : .off
                }
                return currentSpacesSlot() != nil
            }
            return true
        }
        if item.action == #selector(bookmarkThisTab(_:)) {
            return canBookmarkCurrentTab()
        }
        if item.action == #selector(bookmarkAllTabs(_:)) {
            return canBookmarkAllTabs()
        }
        if item.action == #selector(openBookmarkMenuItem(_:)) {
            guard let menuItem = item as? NSMenuItem,
                  let bookmark = menuItem.representedObject as? Bookmark else {
                return false
            }
            return !bookmark.isFolder
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
                #selector(clearLoginStatus(_:)),
                #selector(clearAllUserData(_:)),
                #selector(showExtensionInfo(_:)),
                #selector(exportLogs(_:)),
                #selector(restoreTimeMachineBackup(_:)),
                #selector(exportUserData(_:)),
                #selector(importUserDataFromBackup(_:))
            ]

            if let action = item.action {
                return allowedActions.contains(action)
            }
            return false
        }

        // Command-dispatched main-menu items that reach the app delegate had no
        // key browser window to handle them. Defer their enabled state to
        // PhiAppController (no-window CommandUpdater: New Tab/New Window enabled,
        // tab-only commands disabled), matching upstream AppController.
        if item.action == #selector(commandDispatch(_:)) {
            return ChromiumLauncher.sharedInstance().bridge?.validateUserInterfaceItem(fromMenu: item) ?? false
        }

        return true
    }
    
    @IBAction @objc func commandDispatch(_ sender: Any?) {
        // No key browser window handled this command, so it reached the app
        // delegate. Forward to PhiAppController (via the bridge), which contains
        // the no-window handling for File-menu commands like New Tab/New Window.
        ChromiumLauncher.sharedInstance().bridge?.commandDispatchFromMenu(sender as Any)
    }
}

// MARK: - NSMenuDelegate for Help menu Option key handling
extension AppController: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        if menu.identifier == AppController.bookmarksMenuIdentifier {
            rebuildBookmarksMenu(menu)
            return
        }
        if menu.identifier == AppController.deleteProfileSubmenuIdentifier {
            rebuildDeleteProfileSubmenu(menu)
            return
        }
        if menu.identifier == AppController.spacesMenuIdentifier {
            rebuildSpacesMenu(menu)
            return
        }
        if menu.identifier == AppController.timeMachineBackupsMenuIdentifier {
            rebuildTimeMachineBackupsMenu(menu)
            return
        }

        let optionKeyPressed = NSEvent.modifierFlags.contains(.option)
        if let extensionInfoItem = menu.item(withTag: AppController.extensionInfoItemTag) {
            extensionInfoItem.isHidden = !optionKeyPressed
        }
        if let exportLogsItem = menu.item(withTag: AppController.exportLogsItemTag) {
            exportLogsItem.isHidden = !optionKeyPressed
        }
    }
}

private final class TimeMachineRestoreProgressModal {
    private let window: NSPanel
    private let titleLabel: NSTextField
    private let backupLabel: NSTextField
    private let stageLabel: NSTextField
    private let progressIndicator: NSProgressIndicator

    private(set) var outcome: Result<Void, Error>?

    init(backupTitle: String) {
        window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 156),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = NSLocalizedString("Time Machine Restore", comment: "Time Machine restore progress window title")
        window.level = .modalPanel
        window.isReleasedWhenClosed = false
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true

        titleLabel = NSTextField(labelWithString: NSLocalizedString(
            "Preparing Time Machine Restore",
            comment: "Time Machine restore progress title"
        ))
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        backupLabel = NSTextField(labelWithString: backupTitle)
        backupLabel.font = .systemFont(ofSize: 12)
        backupLabel.textColor = .secondaryLabelColor
        backupLabel.lineBreakMode = .byTruncatingMiddle
        backupLabel.translatesAutoresizingMaskIntoConstraints = false

        stageLabel = NSTextField(labelWithString: Self.message(for: .preparing))
        stageLabel.font = .systemFont(ofSize: 12)
        stageLabel.textColor = .secondaryLabelColor
        stageLabel.lineBreakMode = .byTruncatingTail
        stageLabel.translatesAutoresizingMaskIntoConstraints = false

        progressIndicator = NSProgressIndicator()
        progressIndicator.style = .bar
        progressIndicator.controlSize = .regular
        progressIndicator.minValue = 0
        progressIndicator.maxValue = 100
        progressIndicator.isIndeterminate = true
        progressIndicator.usesThreadedAnimation = true
        progressIndicator.translatesAutoresizingMaskIntoConstraints = false

        let contentView = NSView()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = contentView

        contentView.addSubview(titleLabel)
        contentView.addSubview(backupLabel)
        contentView.addSubview(progressIndicator)
        contentView.addSubview(stageLabel)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 24),

            backupLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            backupLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            backupLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),

            progressIndicator.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            progressIndicator.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            progressIndicator.topAnchor.constraint(equalTo: backupLabel.bottomAnchor, constant: 22),

            stageLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            stageLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            stageLabel.topAnchor.constraint(equalTo: progressIndicator.bottomAnchor, constant: 10)
        ])
    }

    func run() -> NSApplication.ModalResponse {
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        progressIndicator.startAnimation(nil)
        return NSApp.runModal(for: window)
    }

    func update(_ progress: TimeMachineRestorePreparationProgress) {
        stageLabel.stringValue = Self.message(for: progress.stage)
        if let fractionCompleted = progress.fractionCompleted {
            if progressIndicator.isIndeterminate {
                progressIndicator.stopAnimation(nil)
                progressIndicator.isIndeterminate = false
            }
            progressIndicator.doubleValue = fractionCompleted * 100
        } else {
            if !progressIndicator.isIndeterminate {
                progressIndicator.isIndeterminate = true
            }
            progressIndicator.startAnimation(nil)
        }
    }

    func finish(outcome: Result<Void, Error>, response: NSApplication.ModalResponse) {
        self.outcome = outcome
        progressIndicator.stopAnimation(nil)
        NSApp.stopModal(withCode: response)
        window.orderOut(nil)
        window.close()
    }

    private static func message(for stage: TimeMachineRestorePreparationStage) -> String {
        switch stage {
        case .preparing:
            return NSLocalizedString("Preparing restore...", comment: "Time Machine restore progress stage")
        case .downloadingPackage:
            return NSLocalizedString("Downloading rollback package...", comment: "Time Machine restore progress stage")
        case .expandingPackage:
            return NSLocalizedString("Expanding rollback package...", comment: "Time Machine restore progress stage")
        case .validatingPackage:
            return NSLocalizedString("Validating rollback app...", comment: "Time Machine restore progress stage")
        case .preparingInstaller:
            return NSLocalizedString("Preparing installer...", comment: "Time Machine restore progress stage")
        case .launchingInstaller:
            return NSLocalizedString("Starting restore...", comment: "Time Machine restore progress stage")
        case .readyToQuit:
            return NSLocalizedString("Restarting Phi...", comment: "Time Machine restore progress stage")
        }
    }
}

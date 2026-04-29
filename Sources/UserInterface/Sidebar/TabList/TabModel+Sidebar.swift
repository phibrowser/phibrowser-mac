// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
extension Tab: SidebarItem {
    var isBookmark: Bool {
        false
    }
    
    var id: AnyHashable {
        return guid
    }
    
    var iconName: String? {
        return nil // Use faviconUrl instead
    }
    
    var isExpandable: Bool {
        return !subTabs.isEmpty
    }
    
    var hasChildren: Bool {
        return !subTabs.isEmpty
    }
    
    var childrenItems: [SidebarItem] {
        return subTabs
    }
    
    var depth: Int {
        return 0 // Tabs are always at root level in our design
    }
    
    var itemType: SidebarItemType {
        return .tab
    }
    
    func performAction(with owner: SidebarTabListItemOwner?) {
        webContentWrapper?.setAsActiveTab()
    }
    
    var isSelectable: Bool { true }
}

extension Tab: ContextMenuRepresentable {
    @MainActor func makeContextMenu(on menu: NSMenu) {
        menu.removeAllItems()
        
        var items: [NSMenuItem] = []
       
        
        let pinItem = NSMenuItem(title: NSLocalizedString("Pin", comment: "Tab context menu - Menu item to pin the selected tab"), action: #selector(MainBrowserWindowController.togglePin(_:)), keyEquivalent: "")
        if isPinned {
            pinItem.title = NSLocalizedString("Unpin", comment: "Tab context menu - Menu item to unpin the selected tab")
        }
        items.append(pinItem)
        
        let duplicateItem = NSMenuItem(title: NSLocalizedString("Duplicate", comment: "Tab context menu - Menu item to duplicate the selected tab"), action: #selector(duplicateTab), keyEquivalent: "")
        duplicateItem.target = self
        items.append(duplicateItem)

        let copyUrlItem = NSMenuItem(title: NSLocalizedString("Copy Link", comment: "Tab context menu - Menu item to copy the tab URL to clipboard"), action: #selector(MainBrowserWindowController.myCopyLink(_:)), keyEquivalent: "")
        items.append(copyUrlItem)
        
        items.append(.separator())
        
        let isLegacy = MainBrowserWindowControllersManager.shared.activeWindowController?.browserState.layoutMode == .comfortable
        let title = isLegacy ? NSLocalizedString("Add to Bookmark Bar", comment: "Tab context menu - Add current tab to root bookmark bar") :
                               NSLocalizedString("Add to Bookmark", comment: "Tab context menu - Add current tab to root bookmark bar in sidebar")
        let addToRootItem = NSMenuItem(title: title, action: #selector(addTabToRootBookmarks), keyEquivalent: "")
        addToRootItem.target = self
        items.append(addToRootItem)
        
        let addToBookmark = NSMenuItem(title: NSLocalizedString("Add to Folder", comment: "Tab context menu - Menu item to add tab to bookmarks"), action: nil, keyEquivalent: "")
        let bookmarkSubmenu = NSMenu()
        addToBookmark.submenu = bookmarkSubmenu
        
        let folders = MainBrowserWindowControllersManager.shared.activeWindowController?.browserState.bookmarkManager.getAllFolderWithHierarchy() ?? []
        
        let addBookmarkItem = NSMenuItem(title: NSLocalizedString("New Folder", comment: "Sidebar context menu title"), action: #selector(createFolderAndBookmarkTab), keyEquivalent: "")
        addBookmarkItem.target = self
        
        if folders.isEmpty {
            bookmarkSubmenu.addItem(addBookmarkItem)
        } else {
            addToBookmark.isEnabled = true
            buildFolderMenuItems(from: folders, into: bookmarkSubmenu)
            bookmarkSubmenu.addItem(.separator())
            bookmarkSubmenu.addItem(addBookmarkItem)
        }
 
        items.append(addToBookmark)

        items.append(.separator())

        let countBeforeTabGroupBlock = items.count
        appendTabGroupMenuItems(into: &items)
        if items.count > countBeforeTabGroupBlock {
            // Tab-group block contributed entries; close it with a
            // separator before the pin/edit/close block.
            items.append(.separator())
        }
        // If the block was empty (pinned tab), the separator we appended
        // above already serves as the bookmark→pin/close divider.

        if isPinned {
            let editItem = NSMenuItem(title: NSLocalizedString("Edit...", comment: "Pinned tab context menu - Edit pinned tab menu item"), action: #selector(editPinnedTab), keyEquivalent: "")
            editItem.target = self
            items.append(editItem)
        }
        
        if !isPinned || (isPinned && isOpenned) {
            let closeItem = NSMenuItem(title: NSLocalizedString("Close", comment: "Tab context menu - Menu item to close the selected tab"), action: #selector(MainBrowserWindowController.closeTab(_:)), keyEquivalent: "")
            items.append(closeItem)
        }
        
        let closeOther = NSMenuItem(title: NSLocalizedString("Close Other Tabs", comment: "Tab context menu - Menu item to close all tabs except the selected one"), action: #selector(MainBrowserWindowController.closeOther(_:)), keyEquivalent: "")
        items.append(closeOther)
        
        items.forEach { item in
            if item.representedObject == nil {
                item.representedObject = self
            }
            menu.addItem(item)
        }
    }
  
    @objc private func addToBookmarkFolder(_ menuItem: NSMenuItem) {
        guard let folder = menuItem.representedObject as? Bookmark else {
            return
        }
        MainBrowserWindowControllersManager.shared.activeWindowController?.browserState.bookmarkManager.addBookmark(title: title,
                                                                                                                    url: URLProcessor.processUserInput(url ?? ""),
                                                                                                                    to: folder)
    }

    @objc private func addTabToRootBookmarks() {
        MainBrowserWindowControllersManager.shared.activeWindowController?.browserState.bookmarkManager.addBookmark(title: title,
                                                                                                                    url: URLProcessor.processUserInput(url ?? ""),
                                                                                                                    to: nil)
    }
    
    @MainActor
    @objc private func createFolderAndBookmarkTab() {
        guard let windowController = MainBrowserWindowControllersManager.shared.activeWindowController else {
            return
        }
        let state = windowController.browserState
        let tabTitle = title
        let tabURL = URLProcessor.processUserInput(url ?? "")

        EditPinnedTabPresenter.presentModal(
            mode: .newFolder,
            from: windowController.window
        ) { result in
            guard let folderName = result.title, !folderName.isEmpty else { return }
            state.bookmarkManager.addFolderFromTabStrip(
                title: folderName,
                to: nil,
                bookmarkTitle: tabTitle,
                bookmarkURL: tabURL
            ) { _, _ in }
        }
    }
    
    /// Recursively build folder menu items with nested submenus.
    private func buildFolderMenuItems(from folders: [Bookmark], into menu: NSMenu) {
        for folder in folders {
            let folderItem = NSMenuItem(title: folder.title, action: #selector(addToBookmarkFolder(_:)), keyEquivalent: "")
            folderItem.target = self
            folderItem.representedObject = folder
            
            if folder.hasChildren {
                let submenu = NSMenu()
                buildFolderMenuItems(from: folder.children, into: submenu)
                folderItem.submenu = submenu
            }
            
            menu.addItem(folderItem)
        }
    }
 
    @MainActor
    @objc private func editPinnedTab() {
        guard let windowController = MainBrowserWindowControllersManager.shared.activeWindowController else {
            return
        }
        guard let guid = guidInLocalDB, !guid.isEmpty else {
            return
        }
        let state = windowController.browserState
        let pinnedTab = state.pinnedTabs.first(where: { $0.guidInLocalDB == guid })
        let initialURL = pinnedTab?.url ?? url ?? ""
        let initialTitle = pinnedTab?.storedTitle ?? pinnedTab?.title ?? ""
        let pinnedGuid = guid

        EditPinnedTabPresenter.presentModal(mode: .pin,
                                            title: initialTitle,
                                            urlString: initialURL,
                                            from: windowController.window) { [weak windowController] result in
            guard let windowController else { return }
            let state = windowController.browserState
            guard let normalizedURL = state.localStore.normalizedURL(from: result.url) else { return }

            let normalizedString = normalizedURL.absoluteString
            state.localStore.updateTabURL(pinnedGuid, url: normalizedURL)

            if let newTitle = result.title {
                state.localStore.updateTabTitle(pinnedGuid, title: newTitle)
            }

            if let targetTab = state.pinnedTabs.first(where: { $0.guidInLocalDB == pinnedGuid }) {
                if targetTab.url != normalizedString {
                    targetTab.url = normalizedString
                }
                if let newTitle = result.title {
                    targetTab.applyStoredTitle(newTitle)
                }
                if targetTab.isOpenned, let wrapper = targetTab.webContentWrapper {
                    wrapper.updateTabCustomValue("")
                    wrapper.navigate(toURL: normalizedString)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        wrapper.updateTabCustomValue(pinnedGuid)
                    }
                }
            }
        }
    }

    @MainActor
    @objc private func duplicateTab() {
        guard let tabURL = url, !tabURL.isEmpty else { return }
        MainBrowserWindowControllersManager.shared.activeWindowController?.browserState.createTab(tabURL, focusAfterCreate: true)
    }

    /// Builds the tab-group block of the right-click menu. Branches on
    /// `groupToken`:
    ///
    ///   * Ungrouped tab → "New Tab Group" + (when other groups exist)
    ///     "Add to Group ▶" submenu listing this window's groups in
    ///     strip order with color swatches.
    ///   * Grouped tab → "Remove from Group".
    ///
    /// Skipped entirely for pinned tabs and bookmark-backed tabs:
    /// Chromium's TabStripModel doesn't allow pinned tabs to participate
    /// in groups, and Phi's bookmark-backed tabs are an in-app concept
    /// that pre-empts any group affiliation (the tab's identity is the
    /// bookmark, not a free-floating page). Bookmark sidebar rows use a
    /// separate `Bookmark.makeContextMenu` and never reach this method;
    /// this guard catches the case where the tab strip itself contains a
    /// tab whose `guidInLocalDB` resolves to a bookmark (legacy /
    /// traditional layout, where bookmark-opened tabs sit in normalTabs).
    @MainActor
    private func appendTabGroupMenuItems(into items: inout [NSMenuItem]) {
        if isPinned {
            return
        }
        let browserState = MainBrowserWindowControllersManager.shared
            .getBrowserState(for: windowId)
        if isBookmarkBackedTab(state: browserState) {
            return
        }
        if groupToken == nil {
            let newGroupItem = NSMenuItem(
                title: NSLocalizedString(
                    "New Tab Group",
                    comment: "Tab context menu - Add this tab to a newly created tab group"),
                action: #selector(addToNewTabGroup),
                keyEquivalent: "")
            newGroupItem.target = self
            items.append(newGroupItem)

            let orderedGroups = orderedGroupsInStripOrder(state: browserState)
            if !orderedGroups.isEmpty, let browserState {
                let parent = NSMenuItem(
                    title: NSLocalizedString(
                        "Add to Group",
                        comment: "Tab context menu - Submenu to add this tab to an existing tab group"),
                    action: nil,
                    keyEquivalent: "")
                let submenu = NSMenu()
                for group in orderedGroups {
                    let memberCount = browserState.normalTabs
                        .lazy.filter { $0.groupToken == group.token }.count
                    let entry = NSMenuItem(
                        title: group.displayTitle(memberCount: memberCount),
                        action: #selector(addToExistingTabGroup(_:)),
                        keyEquivalent: "")
                    entry.target = self
                    entry.image = NSImage.tabGroupColorSwatch(for: group.color)
                    entry.representedObject = group.token
                    submenu.addItem(entry)
                }
                parent.submenu = submenu
                items.append(parent)
            }
        } else if let currentToken = groupToken {
            // Grouped tab: offer "Move to Group ▶" listing every other
            // group in this window plus "Remove from Group". The move
            // path reuses addTabsToGroup; Chromium's TabStripModel removes
            // the tab from its current group atomically before joining
            // the destination, so a single bridge call suffices.
            let otherGroups = orderedGroupsInStripOrder(state: browserState)
                .filter { $0.token != currentToken }
            if !otherGroups.isEmpty, let browserState {
                let parent = NSMenuItem(
                    title: NSLocalizedString(
                        "Move to Group",
                        comment: "Tab context menu - Submenu to move this tab to another tab group"),
                    action: nil,
                    keyEquivalent: "")
                let submenu = NSMenu()
                for group in otherGroups {
                    let memberCount = browserState.normalTabs
                        .lazy.filter { $0.groupToken == group.token }.count
                    let entry = NSMenuItem(
                        title: group.displayTitle(memberCount: memberCount),
                        action: #selector(addToExistingTabGroup(_:)),
                        keyEquivalent: "")
                    entry.target = self
                    entry.image = NSImage.tabGroupColorSwatch(for: group.color)
                    entry.representedObject = group.token
                    submenu.addItem(entry)
                }
                parent.submenu = submenu
                items.append(parent)
            }

            let moveToNewItem = NSMenuItem(
                title: NSLocalizedString(
                    "Move to New Group",
                    comment: "Tab context menu - Move this tab out of its current group into a newly created group"),
                action: #selector(moveToNewTabGroup),
                keyEquivalent: "")
            moveToNewItem.target = self
            items.append(moveToNewItem)

            let removeItem = NSMenuItem(
                title: NSLocalizedString(
                    "Remove from Group",
                    comment: "Tab context menu - Remove this tab from its tab group"),
                action: #selector(removeFromTabGroup),
                keyEquivalent: "")
            removeItem.target = self
            items.append(removeItem)
        }
    }

    /// True iff this tab is a bookmark-backed tab (its `guidInLocalDB`
    /// resolves to a bookmark in this window's manager). Pinned tabs are
    /// excluded — they have their own localDB binding semantic.
    private func isBookmarkBackedTab(state: BrowserState?) -> Bool {
        guard !isPinned,
              let guid = guidInLocalDB, !guid.isEmpty,
              let state else { return false }
        return state.bookmarkManager.bookmark(withGuid: guid) != nil
    }

    /// Returns this window's tab groups in tab-strip order (first
    /// appearance of each token in `normalTabs`). Matches Chrome's
    /// "Add to Group" submenu ordering.
    private func orderedGroupsInStripOrder(state: BrowserState?)
        -> [WebContentGroupInfo] {
        guard let state else { return [] }
        var seen = Set<String>()
        var ordered: [WebContentGroupInfo] = []
        for tab in state.normalTabs {
            guard let token = tab.groupToken,
                  !seen.contains(token),
                  let info = state.groups[token] else { continue }
            seen.insert(token)
            ordered.append(info)
        }
        return ordered
    }

    @MainActor
    @objc private func addToNewTabGroup() {
        guard let bridge = ChromiumLauncher.sharedInstance().bridge else {
            AppLogDebug("[TAB_GROUPS] addToNewTabGroup: no bridge available")
            return
        }
        let tabIds: [NSNumber] = [NSNumber(value: Int64(guid))]
        let token = bridge.createGroupFromTabs(withWindowId: Int64(windowId),
                                               tabIds: tabIds,
                                               title: nil,
                                               color: nil)
        AppLogDebug("[TAB_GROUPS] addToNewTabGroup: windowId=\(windowId) tabId=\(guid) returned token=\(token)")
    }

    /// Move this (already-grouped) tab into a newly created group.
    /// Reuses `createGroupFromTabs`: Chromium's TabStripModel atomically
    /// detaches the tab from its current group before forming the new
    /// group, so a single bridge call suffices (no separate remove step).
    /// Chromium emits kClosed for the old group if this was its last tab.
    @MainActor
    @objc private func moveToNewTabGroup() {
        guard let bridge = ChromiumLauncher.sharedInstance().bridge else {
            AppLogDebug("[TAB_GROUPS] moveToNewTabGroup: no bridge available")
            return
        }
        let tabIds: [NSNumber] = [NSNumber(value: Int64(guid))]
        let token = bridge.createGroupFromTabs(withWindowId: Int64(windowId),
                                               tabIds: tabIds,
                                               title: nil,
                                               color: nil)
        AppLogDebug("[TAB_GROUPS] moveToNewTabGroup: windowId=\(windowId) tabId=\(guid) returned token=\(token)")
    }

    @MainActor
    @objc private func addToExistingTabGroup(_ sender: NSMenuItem) {
        guard let token = sender.representedObject as? String,
              let bridge = ChromiumLauncher.sharedInstance().bridge else {
            AppLogDebug("[TAB_GROUPS] addToExistingTabGroup: missing token or bridge")
            return
        }
        let tabIds: [NSNumber] = [NSNumber(value: Int64(guid))]
        bridge.addTabsToGroup(withWindowId: Int64(windowId),
                              tabIds: tabIds,
                              tokenHex: token)
        AppLogDebug("[TAB_GROUPS] addToExistingTabGroup windowId=\(windowId) tabId=\(guid) token=\(token)")
    }

    @MainActor
    @objc private func removeFromTabGroup() {
        guard let bridge = ChromiumLauncher.sharedInstance().bridge else {
            AppLogDebug("[TAB_GROUPS] removeFromTabGroup: no bridge available")
            return
        }
        let tabIds: [NSNumber] = [NSNumber(value: Int64(guid))]
        bridge.removeTabsFromGroup(withWindowId: Int64(windowId),
                                   tabIds: tabIds)
        AppLogDebug("[TAB_GROUPS] removeFromTabGroup windowId=\(windowId) tabId=\(guid)")
    }
}

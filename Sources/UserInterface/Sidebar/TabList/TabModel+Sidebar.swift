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
    func makeContextMenu(on menu: NSMenu) {
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
}

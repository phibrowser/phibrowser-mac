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
       
        
        // When the right-clicked tab is part of a split, the pin action operates
        // on the split as a unit — pin moves both panes into `pinnedTabs` and
        // marks the SplitGroup as pinned; unpin reverses that.
        //
        // Pinned-grid cells render record-Tabs whose `guid` does not match the
        // live Chromium tab id the SplitGroup tracks, so resolve via
        // `guidInLocalDB` as a fallback.
        let browserStateForMenu = MainBrowserWindowControllersManager.shared.activeWindowController?.browserState
        let activeSplitGroup: SplitGroup? = {
            if let group = browserStateForMenu?.splitGroup(forTabId: guid) {
                return group
            }
            if let dbGuid = guidInLocalDB, !dbGuid.isEmpty,
               let liveTab = browserStateForMenu?.tabs.first(where: { $0.guidInLocalDB == dbGuid }),
               let group = browserStateForMenu?.splitGroup(forTabId: liveTab.guid) {
                return group
            }
            return nil
        }()
        // Detect pinned-split membership for the right-clicked cell, covering
        // both the live case (`activeSplitGroup?.isPinned`) and the closed
        // case (persisted `splitPartnerGuid` on the pinned record). Without
        // this, right-clicking a pinned-split cell whose panes are both
        // closed falls through to single-tab items.
        let pinnedSplitInfo: (leftTab: Tab, rightTab: Tab, leftDB: String, rightDB: String)? = {
            guard let state = browserStateForMenu,
                  let myDB = guidInLocalDB, !myDB.isEmpty,
                  let pinnedSelf = state.pinnedTabs.first(where: { $0.guidInLocalDB == myDB }),
                  let (leftDB, rightDB) = state.pinnedSplitDBPair(forPinnedTab: pinnedSelf) else {
                return nil
            }
            // Prefer the live Tab when a pane is open (URL reflects in-browser
            // navigation); fall back to the pinned record otherwise.
            let leftTab = state.tabs.first(where: { $0.guidInLocalDB == leftDB })
                ?? state.pinnedTabs.first(where: { $0.guidInLocalDB == leftDB })
            let rightTab = state.tabs.first(where: { $0.guidInLocalDB == rightDB })
                ?? state.pinnedTabs.first(where: { $0.guidInLocalDB == rightDB })
            guard let leftTab, let rightTab else { return nil }
            return (leftTab, rightTab, leftDB, rightDB)
        }()
        let isPinnedSplitCell = pinnedSplitInfo != nil

        let pinItem: NSMenuItem
        if let activeSplitGroup {
            let title = activeSplitGroup.isPinned
                ? NSLocalizedString("Unpin Split", comment: "Tab context menu - Remove the pin from the split that contains this tab")
                : NSLocalizedString("Pin Split", comment: "Tab context menu - Pin the split that contains this tab")
            pinItem = NSMenuItem(title: title,
                                 action: #selector(MainBrowserWindowController.togglePinSplit(_:)),
                                 keyEquivalent: "")
            pinItem.representedObject = activeSplitGroup.id
        } else if let info = pinnedSplitInfo {
            // Closed pinned split — both panes are closed so there's no live
            // splitId. Route through the persistence-aware unpin path that
            // drops the pairing and reopens both URLs as a fresh non-pinned
            // split.
            pinItem = NSMenuItem(title: NSLocalizedString("Unpin Split", comment: "Tab context menu - Remove the pin from the split that contains this tab"),
                                 action: #selector(MainBrowserWindowController.unpinClosedPinnedSplit(_:)),
                                 keyEquivalent: "")
            pinItem.representedObject = [info.leftDB, info.rightDB]
        } else {
            pinItem = NSMenuItem(title: NSLocalizedString("Pin", comment: "Tab context menu - Menu item to pin the selected tab"),
                                 action: #selector(MainBrowserWindowController.togglePin(_:)),
                                 keyEquivalent: "")
            if isPinned {
                pinItem.title = NSLocalizedString("Unpin", comment: "Tab context menu - Menu item to unpin the selected tab")
            }
        }
        items.append(pinItem)
        
        // Pinned splits duplicate as a fresh split (both panes), not just one
        // pane. The handler resolves the (left, right) URL pair via the same
        // `pinnedSplitDBPair` helper used elsewhere on this menu.
        let duplicateItem: NSMenuItem
        if isPinnedSplitCell {
            duplicateItem = NSMenuItem(title: NSLocalizedString("Duplicate Split", comment: "Tab context menu - Duplicate both panes of a pinned split as a new split"),
                                       action: #selector(duplicateSplitTab),
                                       keyEquivalent: "")
        } else {
            duplicateItem = NSMenuItem(title: NSLocalizedString("Duplicate", comment: "Tab context menu - Menu item to duplicate the selected tab"),
                                       action: #selector(duplicateTab),
                                       keyEquivalent: "")
        }
        duplicateItem.target = self
        items.append(duplicateItem)

        // Pinned splits expose one copy item per pane ("Copy URL 1" / "Copy
        // URL 2") so the user can pick which side to copy without having to
        // unpin first. Regular tabs and non-pinned splits keep the single
        // "Copy Link". URLs come from the pair resolved above (live tab when
        // open, persisted pinned record otherwise).
        if let info = pinnedSplitInfo {
            let copyUrl1Item = NSMenuItem(title: NSLocalizedString("Copy URL 1", comment: "Tab context menu - Copy the first pane's URL for a pinned split"),
                                          action: #selector(copySplitPaneURL(_:)),
                                          keyEquivalent: "")
            copyUrl1Item.target = self
            copyUrl1Item.representedObject = info.leftTab.url ?? ""
            items.append(copyUrl1Item)

            let copyUrl2Item = NSMenuItem(title: NSLocalizedString("Copy URL 2", comment: "Tab context menu - Copy the second pane's URL for a pinned split"),
                                          action: #selector(copySplitPaneURL(_:)),
                                          keyEquivalent: "")
            copyUrl2Item.target = self
            copyUrl2Item.representedObject = info.rightTab.url ?? ""
            items.append(copyUrl2Item)
        } else {
            let copyUrlItem = NSMenuItem(title: NSLocalizedString("Copy Link", comment: "Tab context menu - Menu item to copy the tab URL to clipboard"), action: #selector(MainBrowserWindowController.myCopyLink(_:)), keyEquivalent: "")
            items.append(copyUrlItem)
        }

        items.append(.separator())

        // Split view: either dissolve the existing split this tab belongs to,
        // or open a fresh tab paired with this one as a new split. Mutually exclusive.
        if let state = MainBrowserWindowControllersManager.shared.activeWindowController?.browserState {
            if let existingSplit = state.splitGroup(forTabId: guid) {
                // Pinned splits don't expose "Reverse Panes" / "Remove from
                // Split" — those are normal-split affordances. Unpinning a
                // pinned split (via the "Unpin Split" item above) re-renders
                // it as a normal split and the items reappear.
                if !existingSplit.isPinned {
                    let reverseSplitItem = NSMenuItem(
                        title: NSLocalizedString("Reverse Panes", comment: "Tab context menu - Swap the left/right (or top/bottom) panes of the split this tab belongs to"),
                        action: #selector(reverseSplitPanes(_:)),
                        keyEquivalent: "")
                    reverseSplitItem.target = self
                    reverseSplitItem.representedObject = existingSplit.id
                    items.append(reverseSplitItem)

                    let removeSplitItem = NSMenuItem(
                        title: NSLocalizedString("Remove from Split", comment: "Tab context menu - Dissolve the split that contains this tab"),
                        action: #selector(removeFromSplit(_:)),
                        keyEquivalent: "")
                    removeSplitItem.target = self
                    removeSplitItem.representedObject = existingSplit.id
                    items.append(removeSplitItem)
                    items.append(.separator())
                }
            } else if !isPinned {
                let splitItem = NSMenuItem(
                    title: NSLocalizedString("Open as Split", comment: "Tab context menu - Open a new tab as the second pane in a split with this tab"),
                    action: #selector(openAsSplit),
                    keyEquivalent: "")
                splitItem.target = self
                items.append(splitItem)
                items.append(.separator())
            }
        }
        
        // When this tab belongs to a split (normal or pinned), offer one-click
        // actions that persist both panes together. `activeSplitGroup` is the
        // same resolution the pin/unpin items use above, so the entries also
        // appear on pinned-split cells whose `guid` is a synthetic placeholder.
        // `pinnedSplitInfo` covers the unopened pinned split case — both
        // halves are persisted but no live `SplitGroup` exists yet.
        if let splitState = MainBrowserWindowControllersManager.shared.activeWindowController?.browserState,
           (activeSplitGroup != nil || pinnedSplitInfo != nil) {
            let addSplitItem = NSMenuItem(
                title: NSLocalizedString("Add Split to Bookmark", comment: "Tab context menu - Save both panes of the split as a bookmark folder"),
                action: #selector(addSplitToBookmarks(_:)),
                keyEquivalent: "")
            addSplitItem.target = self
            if let activeSplitGroup {
                addSplitItem.representedObject = activeSplitGroup.id
            }
            items.append(addSplitItem)

            // Mirrors the single-tab "Add to Folder" submenu but persists the
            // whole split pair into the chosen folder via
            // `addSplitBookmarkFromTab(_:toFolder:)`. Each folder item carries
            // the `Bookmark` as `representedObject`; the trailing "New Folder"
            // entry presents the modal and creates the split inside the new
            // folder atomically.
            let addSplitToFolder = NSMenuItem(
                title: NSLocalizedString("Add Split to Folder", comment: "Tab context menu - Save both panes of the split into a chosen bookmark folder"),
                action: nil,
                keyEquivalent: "")
            let splitFolderSubmenu = NSMenu()
            addSplitToFolder.submenu = splitFolderSubmenu

            let folders = splitState.bookmarkManager.getAllFolderWithHierarchy()
            let newSplitFolderItem = NSMenuItem(
                title: NSLocalizedString("New Folder", comment: "Sidebar context menu title"),
                action: #selector(createFolderAndBookmarkSplit),
                keyEquivalent: "")
            newSplitFolderItem.target = self

            if folders.isEmpty {
                splitFolderSubmenu.addItem(newSplitFolderItem)
            } else {
                buildSplitFolderMenuItems(from: folders, into: splitFolderSubmenu)
                splitFolderSubmenu.addItem(.separator())
                splitFolderSubmenu.addItem(newSplitFolderItem)
            }
            items.append(addSplitToFolder)
        }

        // Pinned splits skip the single-URL "Add to Bookmark" / "Add to
        // Folder" entries — those would persist only one pane and lose the
        // pairing. "Add Split to Bookmark" above already covers the split
        // case for pinned cells.
        if !isPinnedSplitCell {
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
        }

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

    /// Same shape as `buildFolderMenuItems` but the leaf action wires up the
    /// split-pair save path instead of the single-tab save path.
    private func buildSplitFolderMenuItems(from folders: [Bookmark], into menu: NSMenu) {
        for folder in folders {
            let folderItem = NSMenuItem(title: folder.title, action: #selector(addSplitToBookmarkFolder(_:)), keyEquivalent: "")
            folderItem.target = self
            folderItem.representedObject = folder

            if folder.hasChildren {
                let submenu = NSMenu()
                buildSplitFolderMenuItems(from: folder.children, into: submenu)
                folderItem.submenu = submenu
            }

            menu.addItem(folderItem)
        }
    }

    @MainActor
    @objc private func addSplitToBookmarkFolder(_ menuItem: NSMenuItem) {
        guard let folder = menuItem.representedObject as? Bookmark,
              let state = MainBrowserWindowControllersManager.shared.activeWindowController?.browserState else {
            return
        }
        state.addSplitBookmarkFromTab(self, toFolder: folder)
    }

    @MainActor
    @objc private func createFolderAndBookmarkSplit() {
        guard let windowController = MainBrowserWindowControllersManager.shared.activeWindowController else {
            return
        }
        let state = windowController.browserState

        EditPinnedTabPresenter.presentModal(
            mode: .newFolder,
            from: windowController.window
        ) { [weak self] result in
            guard let self,
                  let folderName = result.title, !folderName.isEmpty else { return }
            // Pre-generate the folder guid so we can place the split bookmark
            // inside it without waiting for the bookmark publisher to refresh
            // and surface a `Bookmark` instance.
            let folderGuid = UUID().uuidString
            state.localStore.createDirectory(title: folderName,
                                             profileId: state.profileId,
                                             parentId: nil,
                                             guid: folderGuid)
            state.addSplitBookmarkFromTab(self, toFolderGuid: folderGuid)
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

        // Pinned-split cells edit both panes in a single sheet so the user
        // doesn't have to unpin to change either side. `pinnedSplitDBPair`
        // returns `(leftDB, rightDB)` in left→right layout order to match the
        // primary/secondary inputs in `EditPinnedTabView`.
        if let pinnedSelf = state.pinnedTabs.first(where: { $0.guidInLocalDB == guid }),
           let (leftDB, rightDB) = state.pinnedSplitDBPair(forPinnedTab: pinnedSelf),
           let leftTab = state.pinnedTabs.first(where: { $0.guidInLocalDB == leftDB }),
           let rightTab = state.pinnedTabs.first(where: { $0.guidInLocalDB == rightDB }) {
            let leftURL = state.pinnedTabEditingURL(for: leftDB, fallbackURL: leftTab.url)
            let leftTitle = leftTab.storedTitle ?? leftTab.title
            let rightURL = state.pinnedTabEditingURL(for: rightDB, fallbackURL: rightTab.url)
            let rightTitle = rightTab.storedTitle ?? rightTab.title

            EditPinnedTabPresenter.presentModal(
                mode: .pin,
                title: leftTitle,
                urlString: leftURL,
                secondaryUrlString: rightURL,
                secondaryTitleString: rightTitle,
                from: windowController.window
            ) { [weak windowController] result in
                guard let windowController else { return }
                let state = windowController.browserState
                Self.applyPinnedTabEdit(pinnedGuid: leftDB,
                                        url: result.url,
                                        title: result.title,
                                        in: state)
                Self.applyPinnedTabEdit(pinnedGuid: rightDB,
                                        url: result.secondaryUrl,
                                        title: result.secondaryTitle,
                                        in: state)
            }
            return
        }

        let pinnedTab = state.pinnedTabs.first(where: { $0.guidInLocalDB == guid })
        let initialURL = state.pinnedTabEditingURL(for: guid, fallbackURL: url)
        let initialTitle = pinnedTab?.storedTitle ?? pinnedTab?.title ?? ""
        let pinnedGuid = guid

        EditPinnedTabPresenter.presentModal(mode: .pin,
                                            title: initialTitle,
                                            urlString: initialURL,
                                            from: windowController.window) { [weak windowController] result in
            guard let windowController else { return }
            let state = windowController.browserState
            Self.applyPinnedTabEdit(pinnedGuid: pinnedGuid,
                                    url: result.url,
                                    title: result.title,
                                    in: state)
        }
    }

    @MainActor
    private static func applyPinnedTabEdit(pinnedGuid: String,
                                           url rawURL: String?,
                                           title newTitle: String?,
                                           in state: BrowserState) {
        guard let rawURL,
              let normalizedURL = state.localStore.normalizedURL(from: rawURL) else { return }

        let normalizedString = normalizedURL.absoluteString
        state.localStore.updateTabURL(pinnedGuid, url: normalizedURL)

        if let newTitle {
            state.localStore.updateTabTitle(pinnedGuid, title: newTitle)
        }

        if let targetTab = state.pinnedTabs.first(where: { $0.guidInLocalDB == pinnedGuid }) {
            targetTab.pinnedUrl = normalizedString
            if targetTab.url != normalizedString {
                targetTab.url = normalizedString
            }
            if let newTitle {
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
    /// Skipped entirely for pinned tabs (Chromium's TabStripModel
    /// doesn't allow them in groups). Also skipped for
    /// bookmark-backed tabs, but only in sidebar layouts: there the
    /// tab's identity is the bookmark itself and group affiliation
    /// would conflict with the bookmark binding. In the Comfortable
    /// horizontal-strip layout these tabs are surfaced as regular
    /// tabs in the strip, so the group menu is available like any
    /// other tab.
    @MainActor
    private func appendTabGroupMenuItems(into items: inout [NSMenuItem]) {
        if isPinned {
            return
        }
        let browserState = MainBrowserWindowControllersManager.shared
            .getBrowserState(for: windowId)
        let inHorizontalStrip = PhiPreferences.GeneralSettings.loadLayoutMode().isTraditional
        if !inHorizontalStrip, isBookmarkBackedTab(state: browserState) {
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

    /// Tab ids to pass to a group-mutation bridge call originating from
    /// this tab. When this tab belongs to a split, both pane ids are
    /// returned so the split joins/leaves the group as a unit. Otherwise
    /// the single tab id is returned. Returned ids deduplicate even when
    /// the partner lookup miraculously returns this tab's own id.
    ///
    /// The Chromium bridge (`tab_groups_proxy.cc::ExpandIndicesToCoverSplits`)
    /// also expands single-pane batches as a backstop; this helper exists
    /// so the Swift optimistic-update loop has the matching list without
    /// needing to know which side did the expansion.
    @MainActor
    private func groupActionTabIds(in state: BrowserState?) -> [Int] {
        guard let state, let split = state.splitGroup(forTabId: guid) else {
            return [guid]
        }
        var ids = [split.primaryTabId, split.secondaryTabId]
        if !ids.contains(guid) {
            ids.append(guid)
        }
        return ids
    }

    @MainActor
    @objc private func addToNewTabGroup() {
        guard let bridge = ChromiumLauncher.sharedInstance().bridge else {
            AppLogDebug("[TAB_GROUPS] addToNewTabGroup: no bridge available")
            return
        }
        let state = MainBrowserWindowControllersManager.shared
            .getBrowserState(for: windowId)
        let memberIds = groupActionTabIds(in: state)
        let tabIds: [NSNumber] = memberIds.map { NSNumber(value: Int64($0)) }
        let token = bridge.createGroupFromTabs(withWindowId: Int64(windowId),
                                               tabIds: tabIds,
                                               title: nil,
                                               color: nil)
        AppLogDebug("[TAB_GROUPS] addToNewTabGroup: windowId=\(windowId) tabIds=\(memberIds) returned token=\(token)")
        if !token.isEmpty {
            for member in memberIds {
                state?.applyOptimisticGroupMembership(tabId: member, newToken: token)
            }
        }
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
        let state = MainBrowserWindowControllersManager.shared
            .getBrowserState(for: windowId)
        let memberIds = groupActionTabIds(in: state)
        let tabIds: [NSNumber] = memberIds.map { NSNumber(value: Int64($0)) }
        let token = bridge.createGroupFromTabs(withWindowId: Int64(windowId),
                                               tabIds: tabIds,
                                               title: nil,
                                               color: nil)
        AppLogDebug("[TAB_GROUPS] moveToNewTabGroup: windowId=\(windowId) tabIds=\(memberIds) returned token=\(token)")
        if !token.isEmpty {
            for member in memberIds {
                state?.applyOptimisticGroupMembership(tabId: member, newToken: token)
            }
        }
    }

    @MainActor
    @objc private func addToExistingTabGroup(_ sender: NSMenuItem) {
        guard let token = sender.representedObject as? String,
              let bridge = ChromiumLauncher.sharedInstance().bridge else {
            AppLogDebug("[TAB_GROUPS] addToExistingTabGroup: missing token or bridge")
            return
        }
        let state = MainBrowserWindowControllersManager.shared
            .getBrowserState(for: windowId)
        let memberIds = groupActionTabIds(in: state)
        let tabIds: [NSNumber] = memberIds.map { NSNumber(value: Int64($0)) }
        bridge.addTabsToGroup(withWindowId: Int64(windowId),
                              tabIds: tabIds,
                              tokenHex: token)
        AppLogDebug("[TAB_GROUPS] addToExistingTabGroup windowId=\(windowId) tabIds=\(memberIds) token=\(token)")
        for member in memberIds {
            state?.applyOptimisticGroupMembership(tabId: member, newToken: token)
        }
    }

    @MainActor
    @objc private func removeFromTabGroup() {
        guard let bridge = ChromiumLauncher.sharedInstance().bridge else {
            AppLogDebug("[TAB_GROUPS] removeFromTabGroup: no bridge available")
            return
        }
        let state = MainBrowserWindowControllersManager.shared
            .getBrowserState(for: windowId)
        let memberIds = groupActionTabIds(in: state)
        let tabIds: [NSNumber] = memberIds.map { NSNumber(value: Int64($0)) }
        bridge.removeTabsFromGroup(withWindowId: Int64(windowId),
                                   tabIds: tabIds)
        AppLogDebug("[TAB_GROUPS] removeFromTabGroup windowId=\(windowId) tabIds=\(memberIds)")
        for member in memberIds {
            state?.applyOptimisticGroupMembership(tabId: member, newToken: nil)
        }
    }

    @MainActor
    @objc private func duplicateSplitTab() {
        guard let state = MainBrowserWindowControllersManager.shared.activeWindowController?.browserState,
              let dbGuid = guidInLocalDB,
              let pinnedSelf = state.pinnedTabs.first(where: { $0.guidInLocalDB == dbGuid }),
              let (leftDB, rightDB) = state.pinnedSplitDBPair(forPinnedTab: pinnedSelf),
              let leftTab = state.pinnedTabs.first(where: { $0.guidInLocalDB == leftDB }),
              let rightTab = state.pinnedTabs.first(where: { $0.guidInLocalDB == rightDB }),
              let leftURL = leftTab.url, !leftURL.isEmpty,
              let rightURL = rightTab.url, !rightURL.isEmpty else {
            return
        }
        state.openTwoURLsAsSplit(primaryURL: leftURL, secondaryURL: rightURL)
    }

    @objc private func copySplitPaneURL(_ sender: NSMenuItem) {
        guard let urlString = sender.representedObject as? String, !urlString.isEmpty else {
            return
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(URLProcessor.phiBrandEnsuredUrlString(urlString), forType: .string)
    }

    @MainActor
    @objc private func addSplitToBookmarks(_ sender: NSMenuItem) {
        // The menu item is only attached when this tab is in a split, so the
        // helper should always succeed here; the bool result is ignored.
        guard let state = MainBrowserWindowControllersManager.shared.activeWindowController?.browserState else { return }
        state.addSplitBookmarkFromTab(self)
    }

    @MainActor
    @objc private func openAsSplit() {
        guard let state = MainBrowserWindowControllersManager.shared.activeWindowController?.browserState else { return }
        state.openNewTabAsSplit(partnerTabId: guid)
    }

    @MainActor
    @objc private func removeFromSplit(_ sender: NSMenuItem) {
        guard let state = MainBrowserWindowControllersManager.shared.activeWindowController?.browserState,
              let splitId = sender.representedObject as? String else { return }
        state.removeSplit(splitId)
    }

    @MainActor
    @objc private func reverseSplitPanes(_ sender: NSMenuItem) {
        guard let state = MainBrowserWindowControllersManager.shared.activeWindowController?.browserState,
              let splitId = sender.representedObject as? String else { return }
        state.reverseTabsInSplit(splitId)
    }
}

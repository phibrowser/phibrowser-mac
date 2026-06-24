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
        Task { @MainActor [windowId] in
            MainBrowserWindowControllersManager.shared
                .getBrowserState(for: windowId)?
                .clearGroupOverview()
        }
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
        // marks the SplitGroup as pinned; unpin reverses that. The same
        // `splitMembership` lookup covers all three cell shapes (live tab,
        // pinned record with live panes, closed pinned split).
        let browserStateForMenu = MainBrowserWindowControllersManager.shared.activeWindowController?.browserState
        let splitMembership = browserStateForMenu?.splitMembership(forCellTab: self)
        let isPinnedSplitCell = splitMembership?.isPinned == true

        let pinItem: NSMenuItem
        if let membership = splitMembership, let liveGroup = membership.liveGroup {
            let title = liveGroup.isPinned
                ? NSLocalizedString("Unpin Split", comment: "Tab context menu - Remove the pin from the split that contains this tab")
                : NSLocalizedString("Pin Split", comment: "Tab context menu - Pin the split that contains this tab")
            pinItem = NSMenuItem(title: title,
                                 action: #selector(MainBrowserWindowController.togglePinSplit(_:)),
                                 keyEquivalent: "")
            pinItem.representedObject = liveGroup.id
        } else if let pair = splitMembership?.pinnedDBPair {
            // Closed pinned split — both panes are closed so there's no live
            // splitId. Route through the persistence-aware unpin path that
            // drops the pairing and reopens both URLs as a fresh non-pinned
            // split.
            pinItem = NSMenuItem(title: NSLocalizedString("Unpin Split", comment: "Tab context menu - Remove the pin from the split that contains this tab"),
                                 action: #selector(MainBrowserWindowController.unpinClosedPinnedSplit(_:)),
                                 keyEquivalent: "")
            pinItem.representedObject = [pair.left, pair.right]
        } else {
            pinItem = NSMenuItem(title: NSLocalizedString("Pin", comment: "Tab context menu - Menu item to pin the selected tab"),
                                 action: #selector(MainBrowserWindowController.togglePin(_:)),
                                 keyEquivalent: "")
            if isPinned {
                pinItem.title = NSLocalizedString("Unpin", comment: "Tab context menu - Menu item to unpin the selected tab")
            }
        }
        items.append(pinItem)
        
        // Resolve the live non-pinned split URL pair (if any) so the
        // duplicate / copy blocks can flip to split-aware variants when the
        // right-clicked cell represents a merged pair. Pinned-split URLs are
        // read directly off the membership panes below.
        let nonPinnedSplitPair: (leftURL: String, rightURL: String)? = {
            guard let membership = splitMembership,
                  membership.liveGroup?.isPinned == false,
                  let leftURL = membership.leftPane.url, !leftURL.isEmpty,
                  let rightURL = membership.rightPane.url, !rightURL.isEmpty else {
                return nil
            }
            return (leftURL, rightURL)
        }()
        let isSplitCell = isPinnedSplitCell || nonPinnedSplitPair != nil

        // Pinned and non-pinned splits both duplicate as a fresh split
        // (both panes), not just one pane.
        let duplicateItem: NSMenuItem
        if isSplitCell {
            duplicateItem = NSMenuItem(title: NSLocalizedString("Duplicate Split", comment: "Tab context menu - Duplicate both panes of a split as a new split"),
                                       action: #selector(duplicateSplitTab),
                                       keyEquivalent: "")
        } else {
            duplicateItem = NSMenuItem(title: NSLocalizedString("Duplicate", comment: "Tab context menu - Menu item to duplicate the selected tab"),
                                       action: #selector(duplicateTab),
                                       keyEquivalent: "")
        }
        duplicateItem.target = self
        items.append(duplicateItem)

        // Splits expose one copy item per pane so the user can pick which
        // side to copy without having to dissolve the split. Regular tabs
        // keep the single "Copy Link".
        let copyLeftURL: String?
        let copyRightURL: String?
        if isPinnedSplitCell, let membership = splitMembership {
            copyLeftURL = membership.leftPane.url
            copyRightURL = membership.rightPane.url
        } else if let pair = nonPinnedSplitPair {
            copyLeftURL = pair.leftURL
            copyRightURL = pair.rightURL
        } else {
            copyLeftURL = nil
            copyRightURL = nil
        }
        if let leftURL = copyLeftURL, let rightURL = copyRightURL {
            let copyLeftURLItem = NSMenuItem(title: NSLocalizedString("Copy Left URL", comment: "Tab context menu - Copy the left pane's URL for a split"),
                                             action: #selector(copySplitPaneURL(_:)),
                                             keyEquivalent: "")
            copyLeftURLItem.target = self
            copyLeftURLItem.representedObject = leftURL
            items.append(copyLeftURLItem)

            let copyRightURLItem = NSMenuItem(title: NSLocalizedString("Copy Right URL", comment: "Tab context menu - Copy the right pane's URL for a split"),
                                              action: #selector(copySplitPaneURL(_:)),
                                              keyEquivalent: "")
            copyRightURLItem.target = self
            copyRightURLItem.representedObject = rightURL
            items.append(copyRightURLItem)
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
            } else if splitMembership == nil {
                // Pinned tabs are allowed here; `openNewTabAsSplit` demotes a
                // pinned partner to the normal list (leaving an unopened
                // pinned placeholder behind) before creating the split, so
                // splits never live inside the pinned strip.
                //
                // When another tab is focused (and isn't itself in a split),
                // the action pairs this tab with the focused one instead of
                // opening a blank new-tab pane — surfaced as "Split with
                // Current". Right-clicking the focused tab itself keeps the
                // blank-pane "Open as Split".
                let splitItem: NSMenuItem
                if let focused = state.focusingTab,
                   focused.guid != guid,
                   state.splitGroup(forTabId: focused.guid) == nil {
                    splitItem = NSMenuItem(
                        title: NSLocalizedString("Split with Current", comment: "Tab context menu - Pair this tab with the currently focused tab in a split"),
                        action: #selector(splitWithCurrent),
                        keyEquivalent: "")
                } else {
                    splitItem = NSMenuItem(
                        title: NSLocalizedString("Open as Split", comment: "Tab context menu - Open a new tab as the second pane in a split with this tab"),
                        action: #selector(openAsSplit),
                        keyEquivalent: "")
                }
                splitItem.target = self
                items.append(splitItem)
                items.append(.separator())
            }
        }
        
        // When this tab belongs to a split (normal or pinned, live or closed)
        // offer one-click actions that persist both panes together. The
        // `splitMembership` lookup above already covers all three shapes.
        if let splitState = MainBrowserWindowControllersManager.shared.activeWindowController?.browserState,
           splitMembership != nil {
            let addSplitItem = NSMenuItem(
                title: NSLocalizedString("Add Split to Bookmark", comment: "Tab context menu - Save both panes of the split as a bookmark folder"),
                action: #selector(addSplitToBookmarks(_:)),
                keyEquivalent: "")
            addSplitItem.target = self
            if let liveGroup = splitMembership?.liveGroup {
                addSplitItem.representedObject = liveGroup.id
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

        // Splits skip the single-URL "Add to Bookmark" / "Add to Folder"
        // entries — those would persist only one pane and lose the pairing.
        // "Add Split to Bookmark" above already covers the split case for
        // both pinned and non-pinned splits.
        if !isSplitCell {
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
                                                                                                                    to: folder,
                                                                                                                    faviconData: liveFaviconData ?? cachedFaviconData)
    }

    @objc private func addTabToRootBookmarks() {
        MainBrowserWindowControllersManager.shared.activeWindowController?.browserState.bookmarkManager.addBookmark(title: title,
                                                                                                                    url: URLProcessor.processUserInput(url ?? ""),
                                                                                                                    to: nil,
                                                                                                                    faviconData: liveFaviconData ?? cachedFaviconData)
    }
    
    @MainActor
    @objc private func createFolderAndBookmarkTab() {
        guard let windowController = MainBrowserWindowControllersManager.shared.activeWindowController else {
            return
        }
        let state = windowController.browserState
        let tabTitle = title
        let tabURL = URLProcessor.processUserInput(url ?? "")
        let tabFaviconData = liveFaviconData ?? cachedFaviconData

        EditPinnedTabPresenter.presentModal(
            mode: .newFolder,
            from: windowController.window
        ) { result in
            guard let folderName = result.title, !folderName.isEmpty else { return }
            state.bookmarkManager.addFolderFromTabStrip(
                title: folderName,
                to: nil,
                bookmarkTitle: tabTitle,
                bookmarkURL: tabURL,
                bookmarkFaviconData: tabFaviconData
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
        state.addSplitBookmarkFromTab(self, toFolder: folder, bindLiveSplit: false)
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
            state.addSplitBookmarkFromTab(self, toFolderGuid: folderGuid, bindLiveSplit: false)
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

    /// Resolves both members of the non-pinned split this tab belongs to,
    /// in primary→secondary order. Returns just `[self.guid]` when the tab
    /// isn't part of a split. The bridge's group ops (`createGroupFromTabs`,
    /// `addTabsToGroup`, `removeTabsFromGroup`) already expand to whole-
    /// split membership Chromium-side via `ExpandIndicesToCoverSplits`, but
    /// the Mac-side optimistic update has to mirror that expansion or the
    /// partner's `groupToken` stays stale until `tabJoinedGroup` rides the
    /// async EventBus hop — the merged-cell invariant in
    /// `normalSplitCollapseInfo` (both panes share the same token) fails
    /// in the meantime and the right pane leaks as a stray chip.
    private func splitAwareGroupMemberIds(state: BrowserState?) -> [NSNumber] {
        var ids: [NSNumber] = [NSNumber(value: Int64(guid))]
        guard let state,
              let group = state.splitGroup(forTabId: guid),
              !group.isPinned,
              let partnerId = group.partnerTabId(of: guid) else {
            return ids
        }
        ids.append(NSNumber(value: Int64(partnerId)))
        return ids
    }

    /// Sheds the bookmark binding from any bookmark-opened member before a
    /// group op. Chromium's `createGroupFromTabs` / `addTabsToGroup` reject a
    /// batch that still contains a Phi-managed (`custom_value`) tab, so an
    /// ungraduated bookmark tab would silently drop the whole request. No-op
    /// for non-bookmark members.
    @MainActor
    private func graduateBookmarkBackedMembers(_ memberIds: [NSNumber], state: BrowserState?) {
        guard let state else { return }
        for member in memberIds {
            if let tab = state.tabs.first(where: { $0.guid == member.intValue }) {
                state.graduateBookmarkTabToPlainTab(tab)
            }
        }
    }

    @MainActor
    @objc private func addToNewTabGroup() {
        guard let bridge = ChromiumLauncher.sharedInstance().bridge else {
            AppLogDebug("[TAB_GROUPS] addToNewTabGroup: no bridge available")
            return
        }
        let state = MainBrowserWindowControllersManager.shared
            .getBrowserState(for: windowId)
        let tabIds = splitAwareGroupMemberIds(state: state)
        // A bookmark-opened tab is Phi-managed (its bookmark guid lives in
        // `custom_value`); Chromium's `createGroupFromTabs` rejects the whole
        // batch if any member is Phi-managed, so the group would never form.
        // Graduate any bookmark-backed member into a plain tab first, matching
        // the drag-into-group path.
        graduateBookmarkBackedMembers(tabIds, state: state)
        let token = bridge.createGroupFromTabs(withWindowId: Int64(windowId),
                                               tabIds: tabIds,
                                               title: nil,
                                               color: nil)
        AppLogDebug("[TAB_GROUPS] addToNewTabGroup: windowId=\(windowId) tabIds=\(tabIds) returned token=\(token)")
        if !token.isEmpty {
            for member in tabIds {
                state?.applyOptimisticGroupMembership(
                    tabId: member.intValue, newToken: token)
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
        let tabIds = splitAwareGroupMemberIds(state: state)
        let token = bridge.createGroupFromTabs(withWindowId: Int64(windowId),
                                               tabIds: tabIds,
                                               title: nil,
                                               color: nil)
        AppLogDebug("[TAB_GROUPS] moveToNewTabGroup: windowId=\(windowId) tabIds=\(tabIds) returned token=\(token)")
        if !token.isEmpty {
            for member in tabIds {
                state?.applyOptimisticGroupMembership(
                    tabId: member.intValue, newToken: token)
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
        let tabIds = splitAwareGroupMemberIds(state: state)
        // Graduate any bookmark-opened member into a plain tab first; Chromium's
        // `addTabsToGroup` rejects the whole batch if any member is Phi-managed.
        graduateBookmarkBackedMembers(tabIds, state: state)
        bridge.addTabsToGroup(withWindowId: Int64(windowId),
                              tabIds: tabIds,
                              tokenHex: token)
        AppLogDebug("[TAB_GROUPS] addToExistingTabGroup windowId=\(windowId) tabIds=\(tabIds) token=\(token)")
        for member in tabIds {
            state?.applyOptimisticGroupMembership(
                tabId: member.intValue, newToken: token)
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
        let tabIds = splitAwareGroupMemberIds(state: state)
        bridge.removeTabsFromGroup(withWindowId: Int64(windowId),
                                   tabIds: tabIds)
        AppLogDebug("[TAB_GROUPS] removeFromTabGroup windowId=\(windowId) tabIds=\(tabIds)")
        for member in tabIds {
            state?.applyOptimisticGroupMembership(
                tabId: member.intValue, newToken: nil)
        }
    }

    @MainActor
    @objc private func duplicateSplitTab() {
        guard let state = MainBrowserWindowControllersManager.shared.activeWindowController?.browserState,
              let membership = state.splitMembership(forCellTab: self),
              let leftURL = membership.leftPane.url, !leftURL.isEmpty,
              let rightURL = membership.rightPane.url, !rightURL.isEmpty else {
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
        state.addSplitBookmarkFromTab(self, bindLiveSplit: false)
    }

    @MainActor
    @objc private func openAsSplit() {
        guard let state = MainBrowserWindowControllersManager.shared.activeWindowController?.browserState else { return }
        // Unopened pinned cell: `guid` here is the synthetic id on the
        // pinned record, not a live Chromium tab. Route through the
        // pinned-URL materialization path so a real partner tab exists
        // by the time the split is formed.
        if !isOpenned,
           let pinnedDBGuid = guidInLocalDB, !pinnedDBGuid.isEmpty {
            let pinnedURLString = pinnedUrl ?? url ?? ""
            if !pinnedURLString.isEmpty {
                state.openNewTabAsSplitFromUnopenedPinned(pinnedDBGuid: pinnedDBGuid,
                                                          url: pinnedURLString)
                return
            }
        }
        state.openNewTabAsSplit(partnerTabId: guid)
    }

    /// "Split with Current": pairs this tab with the currently focused tab
    /// as a vertical split — focused tab stays on the left, this tab takes
    /// the right pane. Both members are normalized first so the split
    /// doesn't inherit pinned-ness or a bookmark binding (mirrors the
    /// drag-onto-page flows in `SplitTabDropContainer`).
    @MainActor
    @objc private func splitWithCurrent() {
        guard let state = MainBrowserWindowControllersManager.shared.activeWindowController?.browserState,
              let focusedId = state.focusingTab?.guid,
              state.splitGroup(forTabId: focusedId) == nil else { return }
        // Unopened pinned cell: `guid` is synthetic, so there is no live tab
        // to pair. Open the pinned URL as a fresh pane next to the focused
        // tab and leave the pinned record intact (mirrors
        // `performSplitDropFromPinned`'s closed-pinned fallback).
        if !isOpenned, let pinnedDBGuid = guidInLocalDB, !pinnedDBGuid.isEmpty {
            let pinnedURLString = pinnedUrl ?? url ?? ""
            guard !pinnedURLString.isEmpty else { return }
            state.makeTabNormalOpened(tabId: focusedId)
            state.openNewTabAsSplit(partnerTabId: focusedId,
                                    partnerNavigateURL: URLProcessor.processUserInput(pinnedURLString))
            return
        }
        guard guid != focusedId else { return }
        state.makeTabNormalOpened(tabId: guid)
        state.makeTabNormalOpened(tabId: focusedId)
        state.createSplit(leftTabId: focusedId, rightTabId: guid, layout: .vertical)
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

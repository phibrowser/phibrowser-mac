// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import SwiftUI
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
            SpaceSessionControllersManager.shared
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
        contextMenuOwnerState = SpaceSessionControllersManager.shared
            .controllerUnderContextClick()?.browserState

        var items: [NSMenuItem] = []
       
        
        // When the right-clicked tab is part of a split, the pin action operates
        // on the split as a unit — pin moves both panes into `pinnedTabs` and
        // marks the SplitGroup as pinned; unpin reverses that. The same
        // `splitMembership` lookup
        // covers all three cell shapes (live tab, pinned record with live
        // panes, closed pinned split).
        let browserStateForMenu = contextMenuState
        let splitMembership = browserStateForMenu?.splitMembership(forCellTab: self)
        let isPinnedSplitCell = splitMembership?.isPinned == true

        // Off-the-record windows (standalone incognito and the Incognito
        // Space) have no pinned tabs and no bookmark writes, so every
        // pin/bookmark item is dropped from the menu rather than disabled.
        let isIncognitoWindow = browserStateForMenu?.isIncognito == true

        if !isIncognitoWindow {
            let pinItem: NSMenuItem?
            if let membership = splitMembership, let liveGroup = membership.liveGroup {
                let title = liveGroup.isPinned
                    ? NSLocalizedString("sidebar.tabContextMenu.unpinLiveSplit", value: "Unpin Split", comment: "Tab context menu - Remove the pin from a live split")
                    : NSLocalizedString("sidebar.tabContextMenu.pinSplit", value: "Pin Split", comment: "Tab context menu - Pin the split that contains this tab")
                let item = NSMenuItem(title: title,
                                      action: #selector(SpaceSessionController.togglePinSplit(_:)),
                                      keyEquivalent: "")
                item.representedObject = liveGroup.id
                pinItem = item
            } else if let dbGuids = splitMembership?.pinnedDBGuids {
                // Closed pinned split — its panes are closed so there's no live
                // splitId. Route through the persistence-aware unpin path that
                // drops the link and reopens every URL as a fresh non-pinned
                // split.
                let item = NSMenuItem(title: NSLocalizedString("sidebar.tabContextMenu.unpinClosedSplit", value: "Unpin Split", comment: "Tab context menu - Remove the pin from a closed pinned split"),
                                      action: #selector(SpaceSessionController.unpinClosedPinnedSplit(_:)),
                                      keyEquivalent: "")
                item.representedObject = dbGuids
                pinItem = item
            } else {
                let item = NSMenuItem(title: NSLocalizedString("sidebar.tabContextMenu.pinTab", value: "Pin", comment: "Tab context menu - Menu item to pin the selected tab"),
                                      action: #selector(SpaceSessionController.togglePin(_:)),
                                      keyEquivalent: "")
                if isPinned {
                    item.title = NSLocalizedString("sidebar.tabContextMenu.unpinTab", value: "Unpin", comment: "Tab context menu - Menu item to unpin the selected tab")
                }
                pinItem = item
            }
            if let pinItem {
                items.append(pinItem)
            }
        }
        
        // Resolve the live non-pinned split's pane URLs (on-screen order, if
        // any) so the duplicate / copy blocks can flip to split-aware
        // variants when the right-clicked cell represents a merged split.
        // Pinned-split URLs are read directly off the membership panes below.
        let nonPinnedSplitURLs: [String]? = {
            guard let membership = splitMembership,
                  membership.liveGroup?.isPinned == false else {
                return nil
            }
            let urls = membership.panes.compactMap { pane -> String? in
                guard let url = pane.url, !url.isEmpty else { return nil }
                return url
            }
            return urls.count == membership.paneCount ? urls : nil
        }()
        let isSplitCell = isPinnedSplitCell || nonPinnedSplitURLs != nil
        // Pinned and non-pinned splits both duplicate as a fresh split (every
        // pane), not just one pane.
        let duplicateItem: NSMenuItem
        if isSplitCell {
            duplicateItem = NSMenuItem(title: NSLocalizedString("sidebar.tabContextMenu.duplicateSplit", value: "Duplicate Split", comment: "Tab context menu - Duplicate both panes of a split as a new split"),
                                       action: #selector(duplicateSplitTab),
                                       keyEquivalent: "")
        } else {
            duplicateItem = NSMenuItem(title: NSLocalizedString("sidebar.tabContextMenu.duplicateTab", value: "Duplicate", comment: "Tab context menu - Menu item to duplicate the selected tab"),
                                       action: #selector(duplicateTab),
                                       keyEquivalent: "")
        }
        duplicateItem.target = self
        items.append(duplicateItem)

        // Splits expose one copy item per pane so the user can pick which
        // pane to copy without having to dissolve the split. Regular tabs
        // keep the single "Copy Link".
        let copyPaneURLs: [String]
        if isPinnedSplitCell, let membership = splitMembership {
            copyPaneURLs = membership.panes.compactMap { pane -> String? in
                guard let url = pane.url, !url.isEmpty else { return nil }
                return url
            }
        } else {
            copyPaneURLs = nonPinnedSplitURLs ?? []
        }
        if copyPaneURLs.count >= 2 {
            let splitLayout = splitMembership?.liveGroup?.layout
                ?? splitMembership?.pinnedDBGuids.flatMap { dbGuids in
                    browserStateForMenu?.pinnedSplitLayout(dbGuids: dbGuids)
                }
                ?? .vertical
            let isStacked = splitLayout == .horizontal
            for (index, paneURL) in copyPaneURLs.enumerated() {
                let title: String
                if copyPaneURLs.count == 2, index == 0 {
                    title = isStacked
                        ? NSLocalizedString("sidebar.tabContextMenu.copyTopPaneURL", value: "Copy Top URL", comment: "Tab context menu - Copy the top pane's URL for a stacked split")
                        : NSLocalizedString("sidebar.tabContextMenu.copyLeftPaneURL", value: "Copy Left URL", comment: "Tab context menu - Copy the left pane's URL for a side-by-side split")
                } else if copyPaneURLs.count == 2 {
                    title = isStacked
                        ? NSLocalizedString("sidebar.tabContextMenu.copyBottomPaneURL", value: "Copy Bottom URL", comment: "Tab context menu - Copy the bottom pane's URL for a stacked split")
                        : NSLocalizedString("sidebar.tabContextMenu.copyRightPaneURL", value: "Copy Right URL", comment: "Tab context menu - Copy the right pane's URL for a side-by-side split")
                } else {
                    // Three or four panes: number them in on-screen order
                    // (left to right, or top to bottom when stacked).
                    title = String(
                        format: NSLocalizedString("sidebar.tabContextMenu.copyPaneURLAtPosition", value: "Copy Pane %d URL", comment: "Tab context menu - Copy one pane's URL of a split with three or four panes; %d is the pane's position counted from the left (or top when stacked), starting at 1"),
                        index + 1)
                }
                let copyPaneURLItem = NSMenuItem(title: title,
                                                 action: #selector(copySplitPaneURL(_:)),
                                                 keyEquivalent: "")
                copyPaneURLItem.target = self
                copyPaneURLItem.representedObject = paneURL
                items.append(copyPaneURLItem)
            }
        } else {
            let copyUrlItem = NSMenuItem(title: NSLocalizedString("sidebar.tabContextMenu.copyTabURL", value: "Copy Link", comment: "Tab context menu - Menu item to copy the tab URL to clipboard"), action: #selector(SpaceSessionController.myCopyLink(_:)), keyEquivalent: "")
            if browserStateForMenu?.focusingTab?.guid == guid {
                applyCopyURLShortcut(to: copyUrlItem)
            }
            items.append(copyUrlItem)
        }

        items.append(.separator())

        // Split view: either act on the existing split this tab belongs to,
        // or open a fresh tab paired with this one as a new split. Mutually exclusive.
        if let state = contextMenuState {
            if let existingSplit = splitMembership?.liveGroup ?? state.splitGroup(forTabId: guid) {
                // The live pane this cell stands for: the cell's own guid for a
                // live tab, or the pinned record's open counterpart.
                let paneTabId = existingSplit.contains(tabId: guid)
                    ? guid
                    : (state.tabs.first { $0.guidInLocalDB == guidInLocalDB && existingSplit.contains(tabId: $0.guid) }?.guid ?? guid)
                // Pinned splits don't expose "Reverse Panes" / "Move Pane" /
                // "Remove from Split" — those are normal-split affordances.
                // Unpinning a pinned split (via the "Unpin Split" item above)
                // re-renders it as a normal split and the items reappear.
                if !existingSplit.isPinned {
                    if existingSplit.isPair {
                        let reverseSplitItem = NSMenuItem(
                            title: NSLocalizedString("sidebar.tabContextMenu.reverseSplitPanes", value: "Reverse Panes", comment: "Tab context menu - Swap the left/right (or top/bottom) panes of the split this tab belongs to"),
                            action: #selector(reverseSplitPanes(_:)),
                            keyEquivalent: "")
                        reverseSplitItem.target = self
                        reverseSplitItem.representedObject = existingSplit.id
                        items.append(reverseSplitItem)
                    } else {
                        // A wider split moves its focused pane one slot at a
                        // time instead of reversing the whole split, whichever
                        // pane's cell the menu opened on. An item that cannot
                        // move — the pane is at that end, or the split has no
                        // focused pane — carries no action so the
                        // auto-enabling menu shows it disabled.
                        let isStacked = existingSplit.layout == .horizontal
                        let focusedPaneTabId = state.focusingTab.map(\.guid)
                            .flatMap { existingSplit.contains(tabId: $0) ? $0 : nil }
                        let focusedPaneSlot = focusedPaneTabId.flatMap { existingSplit.slot(of: $0) }
                        let canMoveBackward = focusedPaneSlot.map { $0 > 0 } ?? false
                        let moveBackwardItem = NSMenuItem(
                            title: isStacked
                                ? NSLocalizedString("sidebar.tabContextMenu.movePaneUp", value: "Move Focused Pane Up", comment: "Tab context menu - Move the focused pane one position up within a stacked split of three or four panes")
                                : NSLocalizedString("sidebar.tabContextMenu.movePaneLeft", value: "Move Focused Pane Left", comment: "Tab context menu - Move the focused pane one position to the left within a side-by-side split of three or four panes"),
                            action: canMoveBackward ? #selector(movePaneBackward(_:)) : nil,
                            keyEquivalent: "")
                        moveBackwardItem.target = self
                        moveBackwardItem.representedObject = focusedPaneTabId
                        moveBackwardItem.isEnabled = canMoveBackward
                        items.append(moveBackwardItem)

                        let canMoveForward = focusedPaneSlot.map { $0 < existingSplit.paneCount - 1 } ?? false
                        let moveForwardItem = NSMenuItem(
                            title: isStacked
                                ? NSLocalizedString("sidebar.tabContextMenu.movePaneDown", value: "Move Focused Pane Down", comment: "Tab context menu - Move the focused pane one position down within a stacked split of three or four panes")
                                : NSLocalizedString("sidebar.tabContextMenu.movePaneRight", value: "Move Focused Pane Right", comment: "Tab context menu - Move the focused pane one position to the right within a side-by-side split of three or four panes"),
                            action: canMoveForward ? #selector(movePaneForward(_:)) : nil,
                            keyEquivalent: "")
                        moveForwardItem.target = self
                        moveForwardItem.representedObject = focusedPaneTabId
                        moveForwardItem.isEnabled = canMoveForward
                        items.append(moveForwardItem)
                    }
                }

                let convertLayoutItem = NSMenuItem(
                    title: existingSplit.layout == .vertical
                        ? NSLocalizedString("sidebar.tabContextMenu.convertToVerticalSplit", value: "Convert to Vertical Split", comment: "Split context menu - Switch a side-by-side split to a stacked split")
                        : NSLocalizedString("sidebar.tabContextMenu.convertToHorizontalSplit", value: "Convert to Horizontal Split", comment: "Split context menu - Switch a stacked split to a side-by-side split"),
                    action: #selector(convertSplitLayout(_:)),
                    keyEquivalent: "")
                convertLayoutItem.target = self
                convertLayoutItem.representedObject = existingSplit.id
                items.append(convertLayoutItem)

                if !existingSplit.isPinned {
                    let removeSplitItem = NSMenuItem(
                        title: NSLocalizedString("sidebar.tabContextMenu.removeFromSplit", value: "Remove from Split", comment: "Tab context menu - Dissolve the split this tab belongs to; every pane becomes a normal tab again"),
                        action: #selector(removeFromSplit(_:)),
                        keyEquivalent: "")
                    removeSplitItem.target = self
                    removeSplitItem.representedObject = paneTabId
                    items.append(removeSplitItem)
                }

                let closeSplitItem = NSMenuItem(
                    title: NSLocalizedString("sidebar.tabContextMenu.closeSplit", value: "Close Split", comment: "Tab context menu - Close every pane of the split that contains this tab"),
                    action: #selector(closeSplit(_:)),
                    keyEquivalent: "")
                closeSplitItem.target = self
                closeSplitItem.representedObject = existingSplit.id
                items.append(closeSplitItem)
                items.append(.separator())
            } else if let dbGuids = splitMembership?.pinnedDBGuids {
                let layout = state.pinnedSplitLayout(dbGuids: dbGuids)
                let convertLayoutItem = NSMenuItem(
                    title: layout == .vertical
                        ? NSLocalizedString("sidebar.tabContextMenu.convertToVerticalSplit", value: "Convert to Vertical Split", comment: "Split context menu - Switch a side-by-side split to a stacked split")
                        : NSLocalizedString("sidebar.tabContextMenu.convertToHorizontalSplit", value: "Convert to Horizontal Split", comment: "Split context menu - Switch a stacked split to a side-by-side split"),
                    action: #selector(convertClosedPinnedSplitLayout(_:)),
                    keyEquivalent: "")
                convertLayoutItem.target = self
                convertLayoutItem.representedObject = dbGuids
                items.append(convertLayoutItem)
                items.append(.separator())
            } else if splitMembership == nil {
                // Pinned tabs are allowed here; `openNewTabAsSplit` demotes a
                // pinned partner to the normal list (leaving an unopened
                // pinned placeholder behind) before creating the split, so
                // splits never live inside the pinned strip.
                //
                // When another tab is focused, and is alone or in a split
                // with room for this tab, the action puts this tab in a split
                // with it instead of opening a blank new-tab pane — surfaced
                // as "Split with Current". Right-clicking the focused tab
                // itself keeps the blank-pane "Open as Split".
                let splitItem: NSMenuItem
                if canSplitWithFocusedTab(in: state) {
                    splitItem = NSMenuItem(
                        title: NSLocalizedString("sidebar.tabContextMenu.splitWithCurrent", value: "Split with Current", comment: "Tab context menu - Pair this tab with the currently focused tab in a split"),
                        action: #selector(splitWithCurrent),
                        keyEquivalent: "")
                } else {
                    splitItem = NSMenuItem(
                        title: NSLocalizedString("sidebar.tabContextMenu.openAsSplit", value: "Open as Split", comment: "Tab context menu - Open a new tab as the second pane in a split with this tab"),
                        action: #selector(openAsSplit),
                        keyEquivalent: "")
                }
                splitItem.target = self
                items.append(splitItem)
                items.append(.separator())
            }
        }
        
        // When this tab belongs to a split (normal or pinned, live or closed)
        // offer one-click actions that persist every pane together. The
        // `splitMembership` lookup above already covers all three shapes.
        if let splitState = contextMenuState,
           !isIncognitoWindow,
           splitMembership != nil {
            let addSplitItem = NSMenuItem(
                title: NSLocalizedString("sidebar.tabContextMenu.addSplitToBookmarks", value: "Add Split to Bookmark", comment: "Tab context menu - Save both panes of the split as a bookmark folder"),
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
                title: NSLocalizedString("sidebar.tabContextMenu.addSplitToFolder", value: "Add Split to Folder", comment: "Tab context menu - Save both panes of the split into a chosen bookmark folder"),
                action: nil,
                keyEquivalent: "")
            let splitFolderSubmenu = NSMenu()
            addSplitToFolder.submenu = splitFolderSubmenu

            let folders = splitState.bookmarkManager.getAllFolderWithHierarchy()
            let newSplitFolderItem = NSMenuItem(
                title: NSLocalizedString("sidebar.tabContextMenu.addSplitToFolder.newFolderAction", value: "New Folder", comment: "Sidebar context menu title"),
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
        // entries — those would persist only one pane and lose the split.
        // "Add Split to Bookmark" above already covers split pairs, pinned
        // and non-pinned alike.
        if !isSplitCell && !isIncognitoWindow {
            let isLegacy = contextMenuState?.layoutMode == .comfortable
            let title = isLegacy ? NSLocalizedString("sidebar.tabContextMenu.addToBookmarkBar", value: "Add to Bookmark Bar", comment: "Tab context menu - Add current tab to root bookmark bar") :
                                   NSLocalizedString("sidebar.tabContextMenu.addToBookmarks", value: "Add to Bookmark", comment: "Tab context menu - Add current tab to root bookmark bar in sidebar")
            let addToRootItem = NSMenuItem(title: title, action: #selector(addTabToRootBookmarks), keyEquivalent: "")
            addToRootItem.target = self
            items.append(addToRootItem)

            let addToBookmark = NSMenuItem(title: NSLocalizedString("sidebar.tabContextMenu.addToFolder", value: "Add to Folder", comment: "Tab context menu - Menu item to add tab to bookmarks"), action: nil, keyEquivalent: "")
            let bookmarkSubmenu = NSMenu()
            addToBookmark.submenu = bookmarkSubmenu

            let folders = contextMenuState?.bookmarkManager.getAllFolderWithHierarchy() ?? []

            let addBookmarkItem = NSMenuItem(title: NSLocalizedString("sidebar.tabContextMenu.addTabToFolder.newFolderAction", value: "New Folder", comment: "Sidebar context menu title"), action: #selector(createFolderAndBookmarkTab), keyEquivalent: "")
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

        // In incognito the whole bookmark block above is skipped, so the
        // previous item may already be a separator — don't stack another.
        if items.last?.isSeparatorItem == false {
            items.append(.separator())
        }

        let countBeforeTabGroupBlock = items.count
        appendTabGroupMenuItems(into: &items)
        if items.count > countBeforeTabGroupBlock {
            // Tab-group block contributed entries; close it with a
            // separator before the pin/edit/close block.
            items.append(.separator())
        }
        // If the block was empty (pinned tab), the separator we appended
        // above already serves as the bookmark→pin/close divider.

        let countBeforeMoveToSpace = items.count
        appendMoveToSpaceMenuItems(into: &items, isSplitCell: isSplitCell)
        if items.count > countBeforeMoveToSpace {
            items.append(.separator())
        }

        if isPinned {
            if !isPinnedSplitCell {
                let iconItem = NSMenuItem(
                    title: NSLocalizedString("sidebar.pinnedTabContextMenu.changeIcon", value: "Change Icon…", comment: "Pinned tab context menu - Open the emoji and icon picker"),
                    action: #selector(changePinnedTabIcon), keyEquivalent: "")
                iconItem.target = self
                items.append(iconItem)
            }
            let editItem = NSMenuItem(title: NSLocalizedString("sidebar.pinnedTabContextMenu.editAction", value: "Edit...", comment: "Pinned tab context menu - Edit pinned tab menu item"), action: #selector(editPinnedTab), keyEquivalent: "")
            editItem.target = self
            if !isSplitCell {
                let parent = NSMenuItem(title: NSLocalizedString("sidebar.pinnedTabContextMenu.editSubmenu", value: "Edit Pinned Tab", comment: "Pinned tab context menu - Submenu for editing the saved pinned tab"), action: nil, keyEquivalent: "")
                let submenu = NSMenu()
                submenu.autoenablesItems = false
                submenu.addItem(editItem)
                let replace = NSMenuItem(title: NSLocalizedString("sidebar.pinnedTabContextMenu.replaceSavedURL", value: "Replace Saved URL with Current", comment: "Pinned tab context menu - Save the open page URL as the pinned tab URL"), action: #selector(replaceSavedPinnedURL), keyEquivalent: "")
                replace.target = self
                replace.isEnabled = contextMenuState?.replacementURLForPinnedTab(self) != nil
                submenu.addItem(replace)
                parent.submenu = submenu
                items.append(parent)
            } else {
                items.append(editItem)
            }
        }
        
        if !isPinned || (isPinned && isOpenned) {
            let closeItem = NSMenuItem(title: NSLocalizedString("sidebar.tabContextMenu.closeTab", value: "Close", comment: "Tab context menu - Menu item to close the selected tab"), action: #selector(SpaceSessionController.closeTab(_:)), keyEquivalent: "")
            items.append(closeItem)
        }
        
        let closeOther = NSMenuItem(title: NSLocalizedString("sidebar.tabContextMenu.closeOtherTabs", value: "Close Other Tabs", comment: "Tab context menu - Menu item to close all tabs except the selected one"), action: #selector(SpaceSessionController.closeOther(_:)), keyEquivalent: "")
        closeOther.target = browserStateForMenu?.windowController
        items.append(closeOther)

        if let state = browserStateForMenu,
           PhiPreferences.GeneralSettings.directionalTabClosingEnabled.loadValue(),
           state.normalTabs.contains(where: { $0 === self }),
           !isPinnedSplitCell, !isPinned {
            for direction in BrowserState.TabCloseDirection.allCases {
                let item = NSMenuItem(
                    title: direction.menuTitle(isHorizontal: state.layoutMode.isTraditional),
                    action: #selector(SpaceSessionController.closeTabsInDirection(_:)),
                    keyEquivalent: "")
                item.tag = direction.rawValue
                item.target = state.windowController
                items.append(item)
            }
        }
        
        items.forEach { item in
            if item.representedObject == nil {
                item.representedObject = self
            }
            menu.addItem(item)
        }
    }

    /// The Space this tab's (or bookmark's) context-menu actions run against:
    /// the one the menu was opened from, else the active one.
    private var contextMenuState: BrowserState? {
        contextMenuOwnerState ?? SpaceSessionControllersManager.shared.activeWindowController?.browserState
    }

    @MainActor
    @objc private func changePinnedTabIcon() {
        guard let window = contextMenuWindowController?.window,
              let anchor = window.contentView,
              let guid = guidInLocalDB,
              let state = contextMenuState,
              state.pinnedTabs.contains(where: { $0.guidInLocalDB == guid }) else { return }
        let targetView = contextMenuAnchorView.flatMap { $0.window === window ? $0 : nil } ?? anchor
        let rect: NSRect
        if targetView === anchor {
            let point = anchor.convert(window.mouseLocationOutsideOfEventStream, from: nil)
            rect = NSRect(x: point.x, y: point.y, width: 1, height: 1)
        } else {
            rect = targetView.bounds
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 262, height: IconPicker.preferredHeight)
        popover.contentViewController = NSHostingController(rootView: IconPicker(
            selected: pinnedIcon.flatMap { IconPickerSelection.fromStorageValue($0) },
            showsGroups: true,
            onReset: { [weak self, weak state, weak popover] in
                self?.setPinnedTabIcon("default", in: state)
                popover?.performClose(nil)
            }
        ) { [weak self, weak state, weak popover] selection in
            self?.setPinnedTabIcon(selection.storageValue, in: state)
            popover?.performClose(nil)
        })
        pinnedIconPopover?.performClose(nil)
        pinnedIconPopover = popover
        RunLoop.main.perform(inModes: [.default]) { [weak self, weak targetView, weak popover] in
            guard self?.pinnedIconPopover === popover,
                  let targetView, let popover else { return }
            popover.show(relativeTo: rect, of: targetView, preferredEdge: .maxY)
        }
    }

    @MainActor
    private func setPinnedTabIcon(_ icon: String, in state: BrowserState?) {
        guard let state, let guid = guidInLocalDB,
              let pinnedTab = state.pinnedTabs.first(where: { $0.guidInLocalDB == guid }) else { return }
        state.localStore.updatePinnedTabIcon(
            resolving: guid, profileId: state.profileId, spaceId: state.spaceId, icon: icon)
        let value = icon == "default" ? nil : icon
        pinnedTab.pinnedIcon = value
        pinnedIcon = value
    }

    @MainActor private var contextMenuWindowController: SpaceSessionController? {
        contextMenuState?.windowController
            ?? SpaceSessionControllersManager.shared.activeWindowController
    }

    private func applyCopyURLShortcut(to item: NSMenuItem) {
        item.tag = CommandWrapper.PHI_COPY_URL.rawValue
        guard let key = Shortcuts.key(for: .PHI_COPY_URL) else { return }
        let menuKey = key.menuKeyEquivalent
        item.keyEquivalent = menuKey.characters
        item.keyEquivalentModifierMask = menuKey.modifiers
    }
  
    @objc private func addToBookmarkFolder(_ menuItem: NSMenuItem) {
        guard let folder = menuItem.representedObject as? Bookmark else {
            return
        }
        contextMenuState?.bookmarkManager.addBookmark(title: title,
                                                                                                                    url: URLProcessor.processUserInput(url ?? ""),
                                                                                                                    to: folder,
                                                                                                                    faviconData: liveFaviconData ?? cachedFaviconData)
    }

    @objc private func addTabToRootBookmarks() {
        contextMenuState?.bookmarkManager.addBookmark(title: title,
                                                                                                                    url: URLProcessor.processUserInput(url ?? ""),
                                                                                                                    to: nil,
                                                                                                                    faviconData: liveFaviconData ?? cachedFaviconData)
    }
    
    @MainActor
    @objc private func createFolderAndBookmarkTab() {
        guard let windowController = contextMenuWindowController else {
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
              let state = contextMenuState else {
            return
        }
        state.addSplitBookmarkFromTab(self, toFolder: folder, bindLiveSplit: false)
    }

    @MainActor
    @objc private func createFolderAndBookmarkSplit() {
        guard let windowController = contextMenuWindowController else {
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
            // Use the scoped manager so the folder and split share a Space.
            state.bookmarkManager.addFolder(title: folderName, guid: folderGuid)
            state.addSplitBookmarkFromTab(self, toFolderGuid: folderGuid, bindLiveSplit: false)
        }
    }


    @MainActor
    @objc private func replaceSavedPinnedURL() {
        contextMenuState?.replaceSavedURLForPinnedTab(self)
    }

    @MainActor
    @objc private func editPinnedTab() {
        guard let windowController = contextMenuWindowController else {
            return
        }
        guard let guid = guidInLocalDB, !guid.isEmpty else {
            return
        }
        let state = windowController.browserState

        // Pinned-split cells edit every pane in a single sheet so the user
        // doesn't have to unpin to change one of them: the first two through
        // the primary/secondary inputs in `EditPinnedTabView`, the third and
        // fourth through its extra-pane inputs.
        if let pinnedSelf = state.pinnedTabs.first(where: { $0.guidInLocalDB == guid }),
           let dbGuids = state.pinnedSplitDBGuids(forPinnedTab: pinnedSelf),
           dbGuids.count >= 2,
           case let leftDB = dbGuids[0], case let rightDB = dbGuids[1],
           let leftTab = state.pinnedTabs.first(where: { $0.guidInLocalDB == leftDB }),
           let rightTab = state.pinnedTabs.first(where: { $0.guidInLocalDB == rightDB }) {
            let extraTabs = dbGuids.dropFirst(2).compactMap { dbGuid in
                state.pinnedTabs.first(where: { $0.guidInLocalDB == dbGuid })
            }
            let extraPanes = extraTabs.map { tab in
                SplitBookmarkExtraPane(
                    url: state.pinnedTabEditingURL(for: tab.guidInLocalDB ?? "", fallbackURL: tab.url),
                    title: tab.storedTitle ?? tab.title
                )
            }
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
                extraPanes: extraPanes,
                from: windowController.window
            ) { [weak windowController, weak leftTab, weak rightTab] result in
                guard let windowController, let leftTab, let rightTab else { return }
                let state = windowController.browserState
                Self.applyPinnedTabEdit(targetTab: leftTab,
                                        url: result.url,
                                        title: result.title,
                                        in: state)
                Self.applyPinnedTabEdit(targetTab: rightTab,
                                        url: result.secondaryUrl,
                                        title: result.secondaryTitle,
                                        in: state)
                // The sheet returns the extra panes in the order it was given.
                // `applyPinnedTabEdit` skips a tab that is no longer pinned.
                for (extraTab, pane) in zip(extraTabs, result.extraPanes ?? []) {
                    Self.applyPinnedTabEdit(targetTab: extraTab,
                                            url: pane.url,
                                            title: pane.title ?? "",
                                            in: state)
                }
            }
            return
        }

        guard let pinnedTab = state.pinnedTabs.first(where: { $0.guidInLocalDB == guid }) else {
            return
        }
        let initialURL = state.pinnedTabEditingURL(for: guid, fallbackURL: url)
        let initialTitle = pinnedTab.storedTitle ?? pinnedTab.title

        EditPinnedTabPresenter.presentModal(mode: .pin,
                                            title: initialTitle,
                                            urlString: initialURL,
                                            from: windowController.window) { [weak windowController, weak pinnedTab] result in
            guard let windowController, let pinnedTab else { return }
            let state = windowController.browserState
            Self.applyPinnedTabEdit(targetTab: pinnedTab,
                                    url: result.url,
                                    title: result.title,
                                    in: state)
        }
    }

    @MainActor
    static func applyPinnedTabEdit(targetTab: Tab,
                                   url rawURL: String?,
                                   title newTitle: String?,
                                   in state: BrowserState) {
        // The edit sheet can stay open while a scope migration replaces the
        // physical database guid. Scope sync retains and rebinds this Tab
        // object, so resolve its current guid only when Save is pressed.
        guard state.pinnedTabs.contains(where: { $0 === targetTab }),
              let pinnedGuid = targetTab.guidInLocalDB,
              !pinnedGuid.isEmpty,
              let rawURL,
              let normalizedURL = state.localStore.normalizedURL(from: rawURL) else { return }

        let normalizedString = normalizedURL.absoluteString
        state.localStore.updatePinnedTab(
            resolving: pinnedGuid,
            profileId: state.profileId,
            spaceId: state.spaceId,
            url: normalizedURL,
            title: newTitle
        )

        targetTab.pinnedUrl = normalizedString
        if targetTab.url != normalizedString {
            targetTab.url = normalizedString
        }
        if let newTitle {
            targetTab.applyStoredTitle(newTitle)
        }
        if targetTab.isOpenned, let wrapper = targetTab.webContentWrapper {
            wrapper.navigateInPlace(toURL: normalizedString)
        }
    }

    @MainActor
    @objc private func duplicateTab() {
        guard let tabURL = url, !tabURL.isEmpty else { return }
        contextMenuState?.createTab(tabURL, focusAfterCreate: true)
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
        let browserState = SpaceSessionControllersManager.shared
            .getBrowserState(for: windowId)
        let inHorizontalStrip = PhiPreferences.GeneralSettings.loadLayoutMode().isTraditional
        if !inHorizontalStrip, isBookmarkBackedTab(state: browserState) {
            return
        }
        if groupToken == nil {
            let newGroupItem = NSMenuItem(
                title: NSLocalizedString("sidebar.tabContextMenu.newTabGroup", value: "New Tab Group",
                    comment: "Tab context menu - Add this tab to a newly created tab group"),
                action: #selector(addToNewTabGroup),
                keyEquivalent: "")
            newGroupItem.target = self
            items.append(newGroupItem)

            let orderedGroups = orderedGroupsInStripOrder(state: browserState)
            if !orderedGroups.isEmpty, let browserState {
                let parent = NSMenuItem(
                    title: NSLocalizedString("sidebar.tabContextMenu.addToGroupSubmenu", value: "Add to Group",
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
                    title: NSLocalizedString("sidebar.tabContextMenu.moveToGroupSubmenu", value: "Move to Group",
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
                title: NSLocalizedString("sidebar.tabContextMenu.moveToNewGroup", value: "Move to New Group",
                    comment: "Tab context menu - Move this tab out of its current group into a newly created group"),
                action: #selector(moveToNewTabGroup),
                keyEquivalent: "")
            moveToNewItem.target = self
            items.append(moveToNewItem)

            let removeItem = NSMenuItem(
                title: NSLocalizedString("sidebar.tabContextMenu.removeFromGroup", value: "Remove from Group",
                    comment: "Tab context menu - Remove this tab from its tab group"),
                action: #selector(removeFromTabGroup),
                keyEquivalent: "")
            removeItem.target = self
            items.append(removeItem)
        }
    }

    /// Appends a "Move to Space ▶" submenu listing every Space except the one
    /// this tab already lives in. Selecting a Space hands the tab to
    /// `SpaceManager.moveTab` — a true cross-window move when the target shares
    /// this tab's profile, or a URL re-open + origin-close across profiles.
    ///
    /// Restricted to plain normal tabs: pinned, split and bookmark-backed tabs
    /// carry per-Space persistence bindings (`guidInLocalDB` / the custom-value
    /// throttle mirror) that a move would strand, and Incognito windows have no
    /// Spaces at all. The submenu is also suppressed when the Spaces feature is
    /// off or no other Space exists.
    @MainActor
    private func appendMoveToSpaceMenuItems(into items: inout [NSMenuItem], isSplitCell: Bool) {
        guard !isPinned, !isSplitCell,
              PhiPreferences.GeneralSettings.spacesFeatureEnabled.loadValue() else { return }
        let sourceState = SpaceSessionControllersManager.shared.getBrowserState(for: windowId)
        guard let sourceState, !sourceState.isIncognito,
              !isBookmarkBackedTab(state: sourceState) else { return }

        // This window's own list: an agent Space hosted by another window is
        // not a destination offered here (`SpaceWindowSlot.presents`).
        let offered = SpaceManager.shared.slot(forWindowId: windowId)?.presentedSpaces
            ?? SpaceManager.shared.spaces
        let targets = offered.filter { $0.spaceId != sourceState.spaceId }
        guard !targets.isEmpty else { return }

        let parent = NSMenuItem(
            title: NSLocalizedString("sidebar.tabContextMenu.moveToSpaceSubmenu", value: "Move to Space",
                comment: "Tab context menu - Submenu to move this tab to another Space"),
            action: nil,
            keyEquivalent: "")
        let submenu = NSMenu()
        for space in targets {
            let entry = NSMenuItem(title: space.name,
                                   action: #selector(moveTabToSpace(_:)),
                                   keyEquivalent: "")
            entry.target = self
            entry.image = SpaceIconView.menuImage(for: space.iconName)
            entry.representedObject = space.spaceId
            submenu.addItem(entry)
        }
        parent.submenu = submenu
        items.append(parent)
    }

    @MainActor
    @objc private func moveTabToSpace(_ sender: NSMenuItem) {
        guard let targetSpaceId = sender.representedObject as? String else { return }
        SpaceManager.shared.moveTab(self, toSpaceId: targetSpaceId)
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

    /// Resolves every pane of the non-pinned split this tab belongs to, in
    /// slot order. Returns just `[self.guid]` when the tab isn't part of a
    /// split. The bridge's group ops (`createGroupFromTabs`,
    /// `addTabsToGroup`, `removeTabsFromGroup`) already expand to whole-
    /// split membership Chromium-side via `ExpandIndicesToCoverSplits`, but
    /// the Mac-side optimistic update has to mirror that expansion or the
    /// other panes' `groupToken` stays stale until `tabJoinedGroup` rides
    /// the async EventBus hop — the merged-cell invariant in
    /// `normalSplitCollapseInfo` (every pane shares the same token) fails
    /// in the meantime and the other panes leak as stray chips.
    private func splitAwareGroupMemberIds(state: BrowserState?) -> [NSNumber] {
        guard let state,
              let group = state.splitGroup(forTabId: guid),
              !group.isPinned else {
            return [NSNumber(value: Int64(guid))]
        }
        return group.tabIds.map { NSNumber(value: Int64($0)) }
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
        let state = SpaceSessionControllersManager.shared
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
        let state = SpaceSessionControllersManager.shared
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
        let state = SpaceSessionControllersManager.shared
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
        let state = SpaceSessionControllersManager.shared
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

    /// Re-opens a split as a fresh split.
    @MainActor
    @objc private func duplicateSplitTab() {
        guard let state = contextMenuState,
              let membership = state.splitMembership(forCellTab: self) else {
            return
        }
        let urls = membership.panes.compactMap { pane in pane.url.flatMap { $0.isEmpty ? nil : $0 } }
        guard urls.count == membership.paneCount else {
            return
        }
        let layout = membership.liveGroup?.layout
            ?? membership.pinnedDBGuids.map { state.pinnedSplitLayout(dbGuids: $0) }
            ?? .vertical
        state.openURLsAsSplit(urls, layout: layout)
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
        guard let state = contextMenuState else { return }
        state.addSplitBookmarkFromTab(self, bindLiveSplit: false)
    }

    @MainActor
    @objc private func openAsSplit() {
        guard let state = contextMenuState else { return }
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
        if state.splitGroup(forTabId: guid) == nil {
            state.makeTabNormalOpened(tabId: guid)
        }
        state.openNewTabAsSplit(partnerTabId: guid)
    }

    /// "Split with Current": pairs this tab with the focused tab, or adds it
    /// to the focused tab's split right after the focused pane.
    @MainActor
    @objc private func splitWithCurrent() {
        guard let state = contextMenuState else { return }
        performSplitAction(in: state)
    }

    /// Dissolves the split this pane belongs to, whatever its width: every
    /// pane becomes a normal tab again. `representedObject` is the pane's
    /// live tab id.
    @MainActor
    @objc private func removeFromSplit(_ sender: NSMenuItem) {
        guard let state = contextMenuState,
              let tabId = sender.representedObject as? Int else { return }
        state.dissolveSplit(containingTabId: tabId)
    }

    /// Moves the focused pane one slot towards the first pane (left / top).
    @MainActor
    @objc private func movePaneBackward(_ sender: NSMenuItem) {
        guard let state = contextMenuState,
              let tabId = sender.representedObject as? Int,
              let slot = state.splitGroup(forTabId: tabId)?.slot(of: tabId), slot > 0 else { return }
        state.moveTabInSplit(tabId: tabId, toSlot: slot - 1)
    }

    /// Moves the focused pane one slot towards the last pane (right / bottom).
    @MainActor
    @objc private func movePaneForward(_ sender: NSMenuItem) {
        guard let state = contextMenuState,
              let tabId = sender.representedObject as? Int,
              let group = state.splitGroup(forTabId: tabId),
              let slot = group.slot(of: tabId), slot < group.paneCount - 1 else { return }
        state.moveTabInSplit(tabId: tabId, toSlot: slot + 1)
    }

    /// Closes every pane of the split. `representedObject` is the split id.
    @MainActor
    @objc private func closeSplit(_ sender: NSMenuItem) {
        guard let state = contextMenuState,
              let splitId = sender.representedObject as? String,
              let group = state.splitGroup(forId: splitId) else { return }
        let panes = group.tabIds.compactMap { id in state.tabs.first { $0.guid == id } }
        state.noteBookmarkSplitClosing(group)
        state.closeTabs(panes)
    }

    @MainActor
    @objc private func reverseSplitPanes(_ sender: NSMenuItem) {
        guard let state = contextMenuState,
              let splitId = sender.representedObject as? String else { return }
        state.reverseTabsInSplit(splitId)
    }

    @MainActor
    @objc private func convertSplitLayout(_ sender: NSMenuItem) {
        guard let state = contextMenuState,
              let splitId = sender.representedObject as? String,
              let group = state.splitGroup(forId: splitId) else { return }
        state.updateSplitLayout(splitId, layout: group.layout.toggled)
    }

    @MainActor
    @objc private func convertClosedPinnedSplitLayout(_ sender: NSMenuItem) {
        guard let state = contextMenuState,
              let dbGuids = sender.representedObject as? [String], dbGuids.count >= 2 else { return }
        let layout = state.pinnedSplitLayout(dbGuids: dbGuids)
        state.updatePinnedSplitLayout(dbGuids: dbGuids, layout: layout.toggled)
    }
}

extension BrowserState.TabCloseDirection {
    func menuTitle(isHorizontal: Bool, relativeToGroup: Bool = false) -> String {
        switch (relativeToGroup, isHorizontal, self) {
        case (false, true, .before):
            return NSLocalizedString("sidebar.tabContextMenu.closeTabsToLeft", value: "Close Tabs to the Left", comment: "Tab context menu - Close ordinary tabs before this tab in a horizontal tab bar")
        case (false, true, .after):
            return NSLocalizedString("sidebar.tabContextMenu.closeTabsToRight", value: "Close Tabs to the Right", comment: "Tab context menu - Close ordinary tabs after this tab in a horizontal tab bar")
        case (false, false, .before):
            return NSLocalizedString("sidebar.tabContextMenu.closeTabsAbove", value: "Close Tabs Above", comment: "Tab context menu - Close ordinary tabs before this tab in a vertical tab bar")
        case (false, false, .after):
            return NSLocalizedString("sidebar.tabContextMenu.closeTabsBelow", value: "Close Tabs Below", comment: "Tab context menu - Close ordinary tabs after this tab in a vertical tab bar")
        case (true, true, .before):
            return NSLocalizedString("sidebar.tabGroupContextMenu.closeTabsToLeft", value: "Close Tabs to the Left of Group", comment: "Tab group context menu - Close ordinary tabs before the group, preserving all its members, in a horizontal tab bar")
        case (true, true, .after):
            return NSLocalizedString("sidebar.tabGroupContextMenu.closeTabsToRight", value: "Close Tabs to the Right of Group", comment: "Tab group context menu - Close ordinary tabs after the group, preserving all its members, in a horizontal tab bar")
        case (true, false, .before):
            return NSLocalizedString("sidebar.tabGroupContextMenu.closeTabsAbove", value: "Close Tabs Above Group", comment: "Tab group context menu - Close ordinary tabs before the group, preserving all its members, in a vertical tab bar")
        case (true, false, .after):
            return NSLocalizedString("sidebar.tabGroupContextMenu.closeTabsBelow", value: "Close Tabs Below Group", comment: "Tab group context menu - Close ordinary tabs after the group, preserving all its members, in a vertical tab bar")
        }
    }
}

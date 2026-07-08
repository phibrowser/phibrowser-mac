// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit

enum TabMultiSelectionMenu {
    /// Populates `menu` with batch actions when a multi-selection is active.
    /// Returns true if it took over the menu; callers must then skip the single-tab menu.
    @MainActor
    static func populateIfNeeded(_ menu: NSMenu, browserState: BrowserState) -> Bool {
        guard browserState.multiSelection.isActive else { return false }
        menu.removeAllItems()

        let controller = TabMultiSelectionMenuController(browserState: browserState)
        let context = browserState.multiSelectionContext
        var items: [NSMenuItem] = []

        let duplicateItem = NSMenuItem(
            title: NSLocalizedString(
                "Duplicate Tabs",
                comment: "Tab multi-selection context menu - duplicate all selected tabs"),
            action: #selector(TabMultiSelectionMenuController.duplicateSelected),
            keyEquivalent: "")
        items.append(duplicateItem)

        let copyLinksItem = NSMenuItem(
            title: NSLocalizedString(
                "Copy Links",
                comment: "Tab multi-selection context menu - copy links of all selected tabs"),
            action: #selector(TabMultiSelectionMenuController.copyLinks),
            keyEquivalent: "")
        items.append(copyLinksItem)

        if context.canOpenAsSplit {
            let openAsSplitItem = NSMenuItem(
                title: NSLocalizedString(
                    "Open as Split",
                    comment: "Tab multi-selection context menu - split exactly two selected tabs into paired panes"),
                action: #selector(TabMultiSelectionMenuController.openSelectedAsSplit),
                keyEquivalent: "")
            items.append(openAsSplitItem)
        }

        items.append(.separator())

        // Bookmark writes are unavailable off-the-record, so incognito
        // windows drop the whole bookmark block instead of disabling it.
        if !browserState.isIncognito {
            let addToBookmarkItem = NSMenuItem(
                title: NSLocalizedString(
                    "Add to Bookmark",
                    comment: "Tab multi-selection context menu - add selected tabs to the root bookmark location"),
                action: #selector(TabMultiSelectionMenuController.addToBookmarkBar),
                keyEquivalent: "")
            addToBookmarkItem.target = controller
            items.append(addToBookmarkItem)

            let addToFolderItem = NSMenuItem(
                title: NSLocalizedString(
                    "Add to Folder",
                    comment: "Tab multi-selection context menu - submenu to add selected tabs to a bookmark folder"),
                action: nil,
                keyEquivalent: "")
            let bookmarkSubmenu = NSMenu()

            let folders = browserState.bookmarkManager.getAllFolderWithHierarchy()
            if !folders.isEmpty {
                buildFolderMenuItems(from: folders, into: bookmarkSubmenu, controller: controller)
                bookmarkSubmenu.addItem(.separator())
            }

            let newFolderItem = NSMenuItem(
                title: NSLocalizedString(
                    "New Folder",
                    comment: "Tab multi-selection context menu - bookmark selected tabs into a newly created folder"),
                action: #selector(TabMultiSelectionMenuController.createNewFolder),
                keyEquivalent: "")
            newFolderItem.target = controller
            bookmarkSubmenu.addItem(newFolderItem)

            addToFolderItem.submenu = bookmarkSubmenu
            items.append(addToFolderItem)

            if !context.containsBookmarkFolder {
                items.append(.separator())
            }
        }

        if !context.containsBookmarkFolder {
            let createGroupItem = NSMenuItem(
                title: NSLocalizedString(
                    "Add Tabs to New Group",
                    comment: "Tab multi-selection context menu - create a new tab group from selected tabs"),
                action: #selector(TabMultiSelectionMenuController.createTabGroup),
                keyEquivalent: "")
            items.append(createGroupItem)

            let orderedGroups = orderedGroupsInStripOrder(state: browserState)
            if !orderedGroups.isEmpty {
                let addToGroup = NSMenuItem(
                    title: NSLocalizedString(
                        "Move Tabs to Group",
                        comment: "Tab multi-selection context menu - submenu to move selected tabs to an existing tab group"),
                    action: nil,
                    keyEquivalent: "")
                let groupSubmenu = NSMenu()
                for group in orderedGroups {
                    let memberCount = browserState.normalTabs
                        .lazy.filter { $0.groupToken == group.token }.count
                    let entry = NSMenuItem(
                        title: group.displayTitle(memberCount: memberCount),
                        action: #selector(TabMultiSelectionMenuController.addToExistingGroup(_:)),
                        keyEquivalent: "")
                    entry.target = controller
                    entry.image = NSImage.tabGroupColorSwatch(for: group.color)
                    entry.representedObject = group.token
                    groupSubmenu.addItem(entry)
                }
                addToGroup.submenu = groupSubmenu
                items.append(addToGroup)
            }
        }

        if context.showsCloseItems {
            items.append(.separator())

            let closeItem = NSMenuItem(
                title: NSLocalizedString(
                    "Close Tabs",
                    comment: "Tab multi-selection context menu - close all selected tabs"),
                action: #selector(TabMultiSelectionMenuController.closeSelected),
                keyEquivalent: "w")
            closeItem.keyEquivalentModifierMask = [.command]
            items.append(closeItem)

            let closeOtherItem = NSMenuItem(
                title: NSLocalizedString(
                    "Close Other Tabs",
                    comment: "Tab multi-selection context menu - close all tabs except the selected ones"),
                action: #selector(TabMultiSelectionMenuController.closeOtherSelected),
                keyEquivalent: "")
            items.append(closeOtherItem)
        }

        items.forEach { item in
            if item.representedObject == nil {
                if item.target == nil { item.target = controller }
                item.representedObject = controller
            }
            menu.addItem(item)
        }
        return true
    }

    private static func buildFolderMenuItems(from folders: [Bookmark],
                                             into menu: NSMenu,
                                             controller: TabMultiSelectionMenuController) {
        for folder in folders {
            let folderItem = NSMenuItem(
                title: folder.title,
                action: #selector(TabMultiSelectionMenuController.addToFolder(_:)),
                keyEquivalent: "")
            folderItem.target = controller
            folderItem.representedObject = folder

            if folder.hasChildren {
                let submenu = NSMenu()
                buildFolderMenuItems(from: folder.children, into: submenu, controller: controller)
                folderItem.submenu = submenu
            }

            menu.addItem(folderItem)
        }
    }

    private static func orderedGroupsInStripOrder(state: BrowserState) -> [WebContentGroupInfo] {
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
}

@MainActor
final class TabMultiSelectionMenuController: NSObject {
    private weak var browserState: BrowserState?
    init(browserState: BrowserState) { self.browserState = browserState }

    @objc func duplicateSelected() { browserState?.duplicateMultiSelectedTabs() }
    @objc func copyLinks() { browserState?.copyLinksOfMultiSelectedTabs() }
    @objc func openSelectedAsSplit() { browserState?.openMultiSelectedTabsAsSplit() }
    @objc func closeSelected() { browserState?.closeMultiSelectedTabs() }
    @objc func closeOtherSelected() { browserState?.closeTabsOutsideMultiSelection() }
    @objc func addToBookmarkBar() { browserState?.bookmarkMultiSelectedTabs(into: nil) }
    @objc func addToFolder(_ sender: NSMenuItem) {
        guard let folder = sender.representedObject as? Bookmark else { return }
        browserState?.bookmarkMultiSelectedTabs(into: folder)
    }
    @objc func createNewFolder() {
        guard let browserState,
              let window = MainBrowserWindowControllersManager.shared.activeWindowController?.window else { return }
        // Snapshot the selection now; the modal dialog clears it before the
        // completion handler runs.
        let tabs = browserState.orderedMultiSelectedTabsIncludingSplitPartners
        EditPinnedTabPresenter.presentModal(mode: .newFolder, from: window) { result in
            guard let name = result.title, !name.isEmpty else { return }
            browserState.bookmarkTabs(tabs, intoNewFolderNamed: name)
        }
    }
    @objc func createTabGroup() { browserState?.groupMultiSelectedTabs() }
    @objc func addToExistingGroup(_ sender: NSMenuItem) {
        guard let token = sender.representedObject as? String else { return }
        browserState?.addMultiSelectedTabs(toGroup: token)
    }

    // Disable a group entry when every selected tab is already in that group.
    @objc func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let browserState else { return true }

        if menuItem.action == #selector(addToExistingGroup(_:)) {
            guard let token = menuItem.representedObject as? String else {
                return false
            }
            return !browserState.multiSelectionTargets(forAddingToGroup: token).isEmpty
        }

        if menuItem.action == #selector(openSelectedAsSplit) {
            return browserState.multiSelectionContext.canOpenAsSplit
        }

        if menuItem.action == #selector(closeOtherSelected) {
            return browserState.hasTabsOutsideMultiSelection
        }

        return true
    }
}

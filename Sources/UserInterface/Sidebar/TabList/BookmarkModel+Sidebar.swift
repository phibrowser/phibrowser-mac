// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
extension Bookmark: SidebarItem {
    var isBookmark: Bool { true }
    
    var id: AnyHashable { return guid }
    
    var iconName: String? {
        return isFolder ? "folder" : "globe"
    }
    
    var isExpandable: Bool {
        return isFolder
    }
    
    var childrenItems: [SidebarItem] {
        return children
    }
    
    var itemType: SidebarItemType {
        return isFolder ? .bookmarkFolder : .bookmark
    }
    
    func performAction(with owner: SidebarTabListItemOwner?) {
        if let _ = url, !isFolder {
            // Open bookmark in new tab or current tab
            owner?.bookmarkClicked(self)
        } else if isFolder {
            owner?.toggleItemExpanded(self)
        }
    }
    
    var isSelectable: Bool {
        return !isFolder
    }
}

enum BookmarkMenuSource {
    case sidebar
    case bookmarkBar
}

// menu
extension Bookmark: ContextMenuRepresentable {
    @MainActor
    func makeContextMenu(on menu: NSMenu) {
        self.makeContextMenu(on: menu, source: .sidebar)
    }

    @MainActor
    func makeContextMenu(on menu: NSMenu, source: BookmarkMenuSource) {
        menu.removeAllItems()
        if !isFolder {
            // Split-view bookmarks expose each URL on its own item — copying
            // both at once isn't useful in practice and matches how the edit
            // dialog separates them. `myCopyLink` reads
            // `WebContentRepresentable.url` (primary only), so the split
            // case needs a dedicated handler routed via the menu item's tag.
            let hasSecondary = !(secondaryUrl ?? "").isEmpty
            if hasSecondary {
                let copyPrimary = NSMenuItem(title: NSLocalizedString("Copy Left URL", comment: "Bookmark context menu - Copy the left (primary) URL of a split-view bookmark"),
                                             action: #selector(copySplitLink(_:)),
                                             keyEquivalent: "")
                copyPrimary.target = self
                copyPrimary.tag = 0
                menu.addItem(copyPrimary)

                let copySecondary = NSMenuItem(title: NSLocalizedString("Copy Right URL", comment: "Bookmark context menu - Copy the right (secondary) URL of a split-view bookmark"),
                                               action: #selector(copySplitLink(_:)),
                                               keyEquivalent: "")
                copySecondary.target = self
                copySecondary.tag = 1
                menu.addItem(copySecondary)
            } else {
                let copyUrlItem = NSMenuItem(title: NSLocalizedString("Copy Link", comment: "Bookmark Copy Link menu item"),
                                             action: #selector(MainBrowserWindowController.myCopyLink(_:)),
                                             keyEquivalent: "")
                copyUrlItem.representedObject = self
                menu.addItem(copyUrlItem)
            }
        }
        
        switch source {
        case .sidebar:
            // Split-view bookmarks have two URLs + two titles, which inline
            // rename can't express — route those through Edit... only.
            let isSplit = !(secondaryUrl ?? "").isEmpty
            if !isSplit {
                let rename = NSMenuItem(title: NSLocalizedString("Rename...", comment: "Bookmark Rename menu item"),
                                        action: #selector(renameBookmark),
                                        keyEquivalent: "")
                rename.target = self
                menu.addItem(rename)
            }
        case .bookmarkBar:
            if isFolder {
                let rename = NSMenuItem(title: NSLocalizedString("Rename...", comment: "Bookmark Rename menu item"),
                                        action: #selector(renameBookmarkFolderModal),
                                        keyEquivalent: "")
                rename.target = self
                menu.addItem(rename)
            }
        }
        
        if isFolder {
            let newFolder = NSMenuItem(title: NSLocalizedString("New Nested Folder...", comment: "Bookmark New Folder menu item"), action: #selector(newFolder), keyEquivalent: "")
            newFolder.target = self
            menu.addItem(newFolder)
        } else {
            let editURL =  NSMenuItem(title: NSLocalizedString("Edit...", comment: "Edit bookmark url menu item title"), action: #selector(edit), keyEquivalent: "")
            editURL.target = self
            menu.addItem(editURL)
            
            // Route split-view bookmarks through a dedicated action that
            // opens a fresh duplicate split without touching the existing
            // bookmark→split binding. The menu title stays "Open in New Tab"
            // for consistency with normal bookmarks.
            let isSplit = !(secondaryUrl ?? "").isEmpty
            let openInNewTab = NSMenuItem(title: NSLocalizedString("Open in New Tab", comment: "Open in New Tab menu item"),
                                          action: isSplit ? #selector(openSplitInNewTab) : #selector(openInNewTab),
                                          keyEquivalent: "")
            openInNewTab.target = self
            menu.addItem(openInNewTab)

            // A split-view bookmark already opens as a split on click, so the
            // explicit "Open as Split" entry would just duplicate the click.
            if !isSplit {
                let openInSplit = NSMenuItem(title: NSLocalizedString("Open as Split", comment: "Bookmark context menu - Open this bookmark as a new tab paired with the current tab in a split"),
                                             action: #selector(openInSplitView),
                                             keyEquivalent: "")
                openInSplit.target = self
                menu.addItem(openInSplit)
            }
        }

        if let state = MainBrowserWindowControllersManager.shared.activeWindowController?.browserState,
           appendSpaceTransferMenuItems(to: menu,
                                        browserState: state,
                                        spaces: SpaceManager.shared.spaces) {
            menu.addItem(.separator())
        }
        
        let delete = NSMenuItem(title: NSLocalizedString("Delete", comment: "Delete bookmark menu item"), action: #selector(myDelete(_:)), keyEquivalent: "")
        delete.target = self
        menu.addItem(delete)
        
    }

    @discardableResult
    @MainActor
    func appendSpaceTransferMenuItems(to menu: NSMenu,
                                      browserState: BrowserState,
                                      spaces: [SpaceModel]) -> Bool {
        let moveTargets = spaces.filter { browserState.canMoveBookmark(self, to: $0) }
        let cloneTargets = spaces.filter { browserState.canCloneBookmark(self, to: $0) }
        guard !moveTargets.isEmpty || !cloneTargets.isEmpty else { return false }

        if !menu.items.isEmpty, menu.items.last?.isSeparatorItem != true {
            menu.addItem(.separator())
        }

        if !moveTargets.isEmpty {
            let parent = NSMenuItem(
                title: NSLocalizedString(
                    "Move to Space",
                    comment: "Bookmark context menu - Submenu to move this bookmark or folder to another Space"),
                action: nil,
                keyEquivalent: "")
            let submenu = NSMenu()
            for space in moveTargets {
                let entry = NSMenuItem(title: space.name,
                                       action: #selector(moveToSpace(_:)),
                                       keyEquivalent: "")
                entry.target = self
                if let icon = NSImage(systemSymbolName: space.iconName, accessibilityDescription: nil) {
                    entry.image = icon
                }
                entry.representedObject = space.spaceId
                submenu.addItem(entry)
            }
            parent.submenu = submenu
            menu.addItem(parent)
        }

        if !cloneTargets.isEmpty {
            let parent = NSMenuItem(
                title: NSLocalizedString(
                    "Clone to Space",
                    comment: "Bookmark context menu - Submenu to clone this bookmark or folder to another Space"),
                action: nil,
                keyEquivalent: "")
            let submenu = NSMenu()
            for space in cloneTargets {
                let entry = NSMenuItem(title: space.name,
                                       action: #selector(cloneToSpace(_:)),
                                       keyEquivalent: "")
                entry.target = self
                if let icon = NSImage(systemSymbolName: space.iconName, accessibilityDescription: nil) {
                    entry.image = icon
                }
                entry.representedObject = space.spaceId
                submenu.addItem(entry)
            }
            parent.submenu = submenu
            menu.addItem(parent)
        }

        return true
    }
    
    @objc private func myDelete(_ item: NSMenuItem) {
        MainBrowserWindowControllersManager.shared.activeWindowController?.browserState.bookmarkManager.removeBookmark(self)
    }

    @MainActor
    @objc private func moveToSpace(_ sender: NSMenuItem) {
        guard let targetSpaceId = sender.representedObject as? String else { return }
        MainBrowserWindowControllersManager.shared.activeWindowController?.browserState
            .moveBookmark(self, toSpaceId: targetSpaceId)
    }

    @MainActor
    @objc private func cloneToSpace(_ sender: NSMenuItem) {
        guard let targetSpaceId = sender.representedObject as? String else { return }
        MainBrowserWindowControllersManager.shared.activeWindowController?.browserState
            .cloneBookmark(self, toSpaceId: targetSpaceId)
    }
    
    @objc private func openInNewTab() {
        guard let _ = url else { return }
        // Open through the bookmark flow so the Chromium tab stays associated.
        MainBrowserWindowControllersManager.shared.activeWindowController?.browserState.createTab(url)
    }

    /// Opens a fresh duplicate split for a split-view bookmark. Intentionally
    /// passes no `bookmarkGuid` so the existing bookmark→split binding (if
    /// any) is preserved and a future click on the bookmark still re-activates
    /// the originally-tracked split rather than this duplicate.
    @MainActor
    @objc private func openSplitInNewTab() {
        guard let url, !url.isEmpty,
              let secondaryURL = secondaryUrl, !secondaryURL.isEmpty,
              let state = MainBrowserWindowControllersManager.shared.activeWindowController?.browserState else { return }
        state.openTwoURLsAsSplit(primaryURL: url, secondaryURL: secondaryURL)
    }

    /// Copies one URL of a split-view bookmark to the pasteboard. The menu
    /// item's `tag` selects which side: 0 = primary, 1 = secondary.
    @objc private func copySplitLink(_ item: NSMenuItem) {
        let raw: String?
        switch item.tag {
        case 0: raw = url
        case 1: raw = secondaryUrl
        default: raw = nil
        }
        guard let raw, !raw.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(URLProcessor.phiBrandEnsuredUrlString(raw), forType: .string)
    }

    @MainActor
    @objc private func openInSplitView() {
        guard let url, !url.isEmpty,
              let state = MainBrowserWindowControllersManager.shared.activeWindowController?.browserState else { return }
        // Pair the bookmark with the focused tab — same path as drag-to-split
        // from the sidebar. If the bookmark already has an attached opened
        // tab, `formSplitFromBookmark` detaches it into the normal list and
        // uses that tab as one pane instead of opening a fresh duplicate.
        // Fall back to the two-fresh-tabs `openURLAsSplit` when there is no
        // valid partner (no focused tab, or the focused tab already lives
        // inside a split — splits can't nest).
        if let partnerTabId = state.focusingTab?.guid,
           state.splitGroup(forTabId: partnerTabId) == nil {
            state.formSplitFromBookmark(bookmarkGuid: guid,
                                        partnerTabId: partnerTabId,
                                        newTabSlot: .left)
            return
        }
        state.openURLAsSplit(url: url)
    }
    
    @objc private func renameBookmark() {
        let state = MainBrowserWindowControllersManager.shared.activeWindowController?.browserState
        // Enter inline edit mode directly instead of showing a dialog.
        state?.bookmarkManager.triggerRename(for: self)
    }

    @MainActor
    @objc private func renameBookmarkFolderModal() {
        guard isFolder else { return }
        edit()
    }
    
    @MainActor
    @objc private func newFolder() {
        guard let windowController = MainBrowserWindowControllersManager.shared.activeWindowController else {
            return
        }
        let state = windowController.browserState
        if state.layoutMode != .comfortable {
            // Create an untitled folder and immediately enter inline edit mode.
            let untitledName = NSLocalizedString("Untitled", comment: "Default name for new bookmark folder")
            state.bookmarkManager.addFolderWithEditing(title: untitledName, to: self)
        } else {
            EditPinnedTabPresenter.presentModal(
                mode: .newFolder,
                from: windowController.window
            ) { [weak self] result in
                guard let self, let folderName = result.title, !folderName.isEmpty else { return }
                state.bookmarkManager.addFolder(title: folderName, to: self)
            }
        }
    }
    
    @MainActor
    @objc private func edit() {
        guard let windowController = MainBrowserWindowControllersManager.shared.activeWindowController else {
            return
        }
        let state = windowController.browserState
        let bookmarkGuid = self.guid
        let originalParentGuid = self.parent?.guid
        // Pass the existing secondary URL and title into the editor so the
        // split-view case shows the second name + URL fields and preserves the
        // values when those rows are left untouched.
        let initialSecondaryUrl = self.secondaryUrl
        let initialSecondaryTitle = self.secondaryTitle
        EditPinnedTabPresenter.presentModal(
            mode: isFolder ? .folder : .bookmark,
            title: title,
            urlString: url ?? "",
            secondaryUrlString: initialSecondaryUrl,
            secondaryTitleString: initialSecondaryTitle,
            modelContainer: state.localStore.container,
            profileId: state.profileId,
            initialFolderGuid: originalParentGuid,
            from: windowController.window,
            onCreateFolder: { folderName in
                let guid = UUID().uuidString
                state.localStore.createDirectory(
                    title: folderName, profileId: state.profileId,
                    parentId: nil, guid: guid
                )
                return guid
            }
        ) { result in
            // Use double-optional for the split fields: `.none` leaves them
            // alone (non-split bookmark untouched), `.some(value)` writes —
            // including `.some("")` to clear. Clearing the secondary URL also
            // clears the secondary title at the persistence layer.
            let secondaryUrlUpdate: String?? = (initialSecondaryUrl == nil) ? nil : .some(result.secondaryUrl ?? "")
            let secondaryTitleUpdate: String?? = (initialSecondaryUrl == nil) ? nil : .some(result.secondaryTitle ?? "")
            state.bookmarkManager.updateBookmark(
                guid: bookmarkGuid,
                title: result.title,
                url: result.url,
                secondaryUrl: secondaryUrlUpdate,
                secondaryTitle: secondaryTitleUpdate
            )
            if let newParentGuid = result.parentFolderGuid,
               newParentGuid != originalParentGuid {
                if let targetFolder = state.bookmarkManager.bookmark(withGuid: newParentGuid) {
                    if let bookmark = state.bookmarkManager.bookmark(withGuid: bookmarkGuid) {
                        state.bookmarkManager.moveBookmark(bookmark, to: targetFolder)
                    }
                } else {
                    state.localStore.moveBookmark(
                        bookmarkGuid, profileId: state.profileId,
                        to: newParentGuid, newIndex: Int.max
                    )
                }
            }
        }
    }
}

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
    func makeContextMenu(on menu: NSMenu) {
        self.makeContextMenu(on: menu, source: .sidebar)
    }

    func makeContextMenu(on menu: NSMenu, source: BookmarkMenuSource) {
        menu.removeAllItems()
        if !isFolder {
            let copyUrlItem = NSMenuItem(title: NSLocalizedString("Copy Link", comment: "Bookmark Copy Link menu item"), action: #selector(MainBrowserWindowController.myCopyLink(_:)), keyEquivalent: "")
            copyUrlItem.representedObject = self
            menu.addItem(copyUrlItem)
        }
        
        switch source {
        case .sidebar:
            let rename = NSMenuItem(title: NSLocalizedString("Rename...", comment: "Bookmark Rename menu item"),
                                    action: #selector(renameBookmark),
                                    keyEquivalent: "")
            rename.target = self
            menu.addItem(rename)
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
            
            let openInNewTab = NSMenuItem(title: NSLocalizedString("Open in New Tab", comment: "Open in New Tab menu item"), action: #selector(openInNewTab), keyEquivalent: "")
            openInNewTab.target = self
            menu.addItem(openInNewTab)
        }
        
        let delete = NSMenuItem(title: NSLocalizedString("Delete", comment: "Delete bookmark menu item"), action: #selector(myDelete(_:)), keyEquivalent: "")
        delete.target = self
        menu.addItem(delete)
        
    }
    
    @objc private func myDelete(_ item: NSMenuItem) {
        MainBrowserWindowControllersManager.shared.activeWindowController?.browserState.bookmarkManager.removeBookmark(self)
    }
    
    @objc private func openInNewTab() {
        guard let _ = url else { return }
        // Open through the bookmark flow so the Chromium tab stays associated.
        MainBrowserWindowControllersManager.shared.activeWindowController?.browserState.createTab(url)
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
        EditPinnedTabPresenter.presentModal(
            mode: isFolder ? .folder : .bookmark,
            title: title,
            urlString: url ?? "",
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
            state.bookmarkManager.updateBookmark(
                guid: bookmarkGuid,
                title: result.title,
                url: result.url
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

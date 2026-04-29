// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
extension BrowserState {
    private func syncBookmarkBinding(_ bookmark: Bookmark, with tab: Tab?, focusingTabGuid: Int?) {
        if let tab {
            if !bookmark.isOpened {
                bookmark.isOpened = true
            }
            if bookmark.chromiumTabGuid != tab.guid {
                bookmark.chromiumTabGuid = tab.guid
            }
            bookmark.setWebContentWrapper(tab.webContentWrapper)

            let isActive = (tab.guid == focusingTabGuid)
            if bookmark.isActive != isActive {
                bookmark.isActive = isActive
            }
        } else {
            if bookmark.isOpened {
                bookmark.isOpened = false
            }
            if bookmark.chromiumTabGuid != -1 {
                bookmark.chromiumTabGuid = -1
            }
            bookmark.setWebContentWrapper(nil)
            if bookmark.isActive {
                bookmark.isActive = false
            }
        }
    }

    @MainActor
    func displayNewFolderDialog(_ name: String? = nil, placeholder: String? = nil, isFolder: Bool) async -> String? {
        let alert = NSAlert()
        alert.messageText = (name?.isEmpty == true || isFolder) ? NSLocalizedString("New Folder", comment: "New folder dialog title")
        : NSLocalizedString("Rename", comment: "Rename folder or bookmark dialog title")
        alert.alertStyle = .informational


        let inputField = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        inputField.placeholderString = placeholder ?? NSLocalizedString("Folder Name", comment: "New folder dialog input placeholder")
        inputField.stringValue = name ?? ""
        alert.accessoryView = inputField

        alert.addButton(withTitle: NSLocalizedString("Confirm", comment: "New folder dialog confirm button title"))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "New folder dialog cancel button title"))

        let response: NSApplication.ModalResponse
        if let window = self.windowController?.window  {
            response = await alert.beginSheetModal(for: window)
        } else {
            response = alert.runModal()
        }
        if response == .alertFirstButtonReturn {
            let name = inputField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            return name
        } else {
            return nil
        }
    }

    @MainActor
    func displayRenameBookmarkDialog(initialName: String) async -> String? {
        return await displayNewFolderDialog(initialName, placeholder: "", isFolder: false)
    }

    @MainActor
    func displayRenameBookmarkFolderDialog(initialName: String) async -> String? {
        return await displayNewFolderDialog(initialName, placeholder: "", isFolder: true)
    }
    
    func createDirectory(title: String,
                         parentId: String?,
                         index: Int? = nil) {
        localStore.createDirectory(title: title, profileId: profileId, parentId: parentId)
    }
    
    func addBookmark(url: String, title: String, parentId: String) {
        localStore.createBookmark(url: url, title: title, profileId: profileId, parentId: parentId)
    }
    
    /// Activates the existing tab for a bookmark or creates a new tab when needed.
    func openBookmark(_ bookmark: Bookmark) {
        guard !bookmark.isFolder, let url = bookmark.url else { return }
        
        guard let realBookmark = bookmarkManager.bookmark(withGuid: bookmark.guid) else {
            createTab(url, customGuid: nil, focusAfterCreate: true)
            return
        }
        
        if realBookmark.isOpened, let wrapper = realBookmark.webContentWrapper {
            wrapper.setAsActiveTab()
        } else {
            createTab(URLProcessor.processUserInput(url), customGuid: realBookmark.guid, focusAfterCreate: true)
        }
    }
    
    /// Closes the currently open tab associated with a bookmark.
    func closeBookmark(_ bookmark: Bookmark) {
        guard let realBookmark = bookmarkManager.bookmark(withGuid: bookmark.guid) else {
            return
        }
        
        if realBookmark.isOpened, realBookmark.chromiumTabGuid != -1 {
            if let tab = tabs.first(where: { $0.guid == realBookmark.chromiumTabGuid }) {
                tab.close()
            }
        }
    }
    
    /// Marks a bookmark as opened when a tab is created for its local guid.
    func handleBookmarkTabOpened(_ tab: Tab) {
        guard let localGuid = tab.guidInLocalDB, !localGuid.isEmpty else {
            return
        }
        
        if let bookmark = bookmarkManager.bookmark(withGuid: localGuid) {
            syncBookmarkBinding(bookmark, with: tab, focusingTabGuid: focusingTab?.guid)
        }
    }
    
    /// Clears bookmark-open state when its linked tab closes.
    func handleBookmarkTabClosed(_ tab: Tab) {
        guard let localGuid = tab.guidInLocalDB, !localGuid.isEmpty else {
            return
        }
        
        if let bookmark = bookmarkManager.bookmark(withGuid: localGuid) {
            syncBookmarkBinding(bookmark, with: nil, focusingTabGuid: focusingTab?.guid)
        }
    }
    
    /// Recomputes open-state flags for all bookmarks from the current tab list.
    func syncAllBookmarksOpenedState() {
        let allBookmarks = bookmarkManager.getAllBookmarks()
        let focusingTabGuid = focusingTab?.guid
        
        for bookmark in allBookmarks {
            guard !bookmark.isFolder else { continue }
            
            if let matchedTab = tabs.first(where: { $0.guidInLocalDB == bookmark.guid }) {
                syncBookmarkBinding(bookmark, with: matchedTab, focusingTabGuid: focusingTabGuid)
            } else {
                syncBookmarkBinding(bookmark, with: nil, focusingTabGuid: focusingTabGuid)
            }
        }
        
        updateNormalTabs()
    }
}

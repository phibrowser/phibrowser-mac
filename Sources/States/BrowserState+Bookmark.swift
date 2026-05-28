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

    /// If `tab` belongs to a split pair, save the whole pair as one split-view
    /// bookmark and return true. Otherwise return false so the caller can fall
    /// back to a single-URL bookmark path.
    ///
    /// The live split is bound to the new bookmark via `splitBookmarkBindings`
    /// — mirroring the single-tab `moveNormalTab(tabId:toBookmark:index:)`
    /// behavior where the dragged tab becomes the opened representation of
    /// the new bookmark cell. The two panes stay alive (a split bookmark
    /// can't be bound to a single live tab via `guidInLocalDB`), but the
    /// binding hides them from the normal tab list via
    /// `splitBookmarkBoundTabIds` in `updateNormalTabs`.
    @discardableResult
    func addSplitBookmarkFromTab(_ tab: Tab,
                                 toFolder parent: Bookmark? = nil,
                                 toFolderGuid: String? = nil,
                                 targetIndex: Int? = nil) -> Bool {
        // Pinned-split cells render synthetic-`guid` records; their `guid`
        // doesn't match the live SplitGroup's tab ids. Fall back to a
        // `guidInLocalDB` lookup so the context-menu actions can pass the
        // record-tab directly without each caller having to resolve.
        let resolvedTab: Tab? = {
            if splitGroup(forTabId: tab.guid) != nil { return tab }
            guard let dbGuid = tab.guidInLocalDB, !dbGuid.isEmpty else { return nil }
            return tabs.first(where: { $0.guidInLocalDB == dbGuid })
        }()
        let parentGuid = toFolderGuid ?? parent?.guid
        if let resolvedTab,
           let group = splitGroup(forTabId: resolvedTab.guid),
           let primaryTab = tabs.first(where: { $0.guid == group.primaryTabId }),
           let secondaryTab = tabs.first(where: { $0.guid == group.secondaryTabId }),
           let primaryURL = primaryTab.url, !primaryURL.isEmpty,
           let secondaryURL = secondaryTab.url, !secondaryURL.isEmpty {
            let bookmarkTitle = primaryTab.title.isEmpty ? primaryURL : primaryTab.title
            // Suppress the secondary title when it would just duplicate the
            // primary (common for two halves of the same page) so the bookmark
            // bar label stays compact.
            let secondaryDisplayTitle: String? = {
                if primaryTab.title == secondaryTab.title { return nil }
                return secondaryTab.title.isEmpty ? nil : secondaryTab.title
            }()
            let newBookmarkGuid = UUID().uuidString
            // `toFolderGuid` lets the "New Folder" flow target a folder created
            // with a pre-generated guid before its Bookmark instance has been
            // published into the tree. Falls back to `parent?.guid` for the
            // common case where the caller already holds the Bookmark.
            // Use `localStore.createBookmark` directly so we control the guid and
            // can register the bookmark→split binding immediately, before the
            // bookmark publisher republishes the tree.
            localStore.createBookmark(
                url: URLProcessor.processUserInput(primaryURL),
                title: bookmarkTitle,
                profileId: profileId,
                parentId: parentGuid,
                index: targetIndex,
                guid: newBookmarkGuid,
                secondaryUrl: URLProcessor.processUserInput(secondaryURL),
                secondaryTitle: secondaryDisplayTitle
            )
            // For pinned splits, "Add Split to Bookmark" should only persist the
            // bookmark — the live pinned split must stay pinned and unbound so it
            // doesn't get re-rendered as the bookmark's opened representation.
            // The drag-from-pinned-split path (`savePinnedSplitAsBookmark`)
            // intentionally unpins and binds; the menu click does not.
            if !group.isPinned {
                splitBookmarkBindings[newBookmarkGuid] = group.id
            }
            updateNormalTabs()
            return true
        }
        // Unopened pinned split: no live SplitGroup, but the two halves are
        // persisted as paired records in `pinnedTabs`. Build the bookmark
        // from each pinned record's persisted URL/title so the right-click
        // "Add Split to Bookmark / Folder" works on a cell whose panes
        // haven't been opened in this session yet.
        if let myDB = tab.guidInLocalDB, !myDB.isEmpty,
           let pinnedSelf = pinnedTabs.first(where: { $0.guidInLocalDB == myDB }),
           let (leftDB, rightDB) = pinnedSplitDBPair(forPinnedTab: pinnedSelf),
           let leftPinned = pinnedTabs.first(where: { $0.guidInLocalDB == leftDB }),
           let rightPinned = pinnedTabs.first(where: { $0.guidInLocalDB == rightDB }),
           let primaryURL = leftPinned.url, !primaryURL.isEmpty,
           let secondaryURL = rightPinned.url, !secondaryURL.isEmpty {
            let primaryTitle = leftPinned.title
            let secondaryTitle = rightPinned.title
            let bookmarkTitle = primaryTitle.isEmpty ? primaryURL : primaryTitle
            let secondaryDisplayTitle: String? = {
                if primaryTitle == secondaryTitle { return nil }
                return secondaryTitle.isEmpty ? nil : secondaryTitle
            }()
            localStore.createBookmark(
                url: URLProcessor.processUserInput(primaryURL),
                title: bookmarkTitle,
                profileId: profileId,
                parentId: parentGuid,
                index: targetIndex,
                guid: UUID().uuidString,
                secondaryUrl: URLProcessor.processUserInput(secondaryURL),
                secondaryTitle: secondaryDisplayTitle
            )
            return true
        }
        return false
    }
    
    /// Activates the existing tab for a bookmark or creates a new tab when needed.
    /// Split bookmarks consult `splitBookmarkBindings` to find the split that
    /// was opened from this bookmark — if it still exists the primary pane is
    /// re-activated; otherwise a fresh split is opened and registered.
    func openBookmark(_ bookmark: Bookmark) {
        guard !bookmark.isFolder, let url = bookmark.url else { return }

        if let secondaryURL = bookmark.secondaryUrl, !secondaryURL.isEmpty {
            if let splitId = splitBookmarkBindings[bookmark.guid],
               let group = splits.first(where: { $0.id == splitId }),
               let primaryTab = tabs.first(where: { $0.guid == group.primaryTabId }),
               let wrapper = primaryTab.webContentWrapper {
                wrapper.setAsActiveTab()
            } else {
                openTwoURLsAsSplit(primaryURL: url,
                                   secondaryURL: secondaryURL,
                                   bookmarkGuid: bookmark.guid)
            }
            return
        }

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

    /// Mirror the split-bookmark binding state onto the bookmark's published
    /// flags so the sidebar/bookmark-bar cell reads "opened"/"active" the
    /// same way a normal bookmark does. Call after mutating
    /// `splitBookmarkBindings` or after the focused tab changes.
    func syncSplitBookmarkOpenedState(bookmarkGuid: String) {
        guard let bookmark = bookmarkManager.bookmark(withGuid: bookmarkGuid) else { return }
        let isOpened = splitBookmarkBindings[bookmarkGuid] != nil
        if bookmark.isOpened != isOpened { bookmark.isOpened = isOpened }
        // Split bookmarks don't bind a single `webContentWrapper`; clear it
        // and reset chromiumTabGuid so the normal-bookmark code paths (e.g.
        // `closeBookmark`'s wrapper lookup) don't accidentally pick a stale
        // tab. The split-aware activate/close paths read
        // `splitBookmarkBindings` directly.
        if bookmark.chromiumTabGuid != -1 { bookmark.chromiumTabGuid = -1 }
        bookmark.setWebContentWrapper(nil)
        let isActive: Bool = {
            guard let splitId = splitBookmarkBindings[bookmarkGuid],
                  let group = splits.first(where: { $0.id == splitId }),
                  let focusedId = focusingTab?.guid else { return false }
            return group.contains(tabId: focusedId)
        }()
        if bookmark.isActive != isActive { bookmark.isActive = isActive }
    }
    
    /// Closes the currently open tab(s) associated with a bookmark. For split
    /// bookmarks both panes are closed via the binding map.
    func closeBookmark(_ bookmark: Bookmark) {
        guard let realBookmark = bookmarkManager.bookmark(withGuid: bookmark.guid) else {
            return
        }

        if let splitId = splitBookmarkBindings[realBookmark.guid],
           let group = splits.first(where: { $0.id == splitId }) {
            // Snapshot the tab ids before closing — closing the first tab
            // dissolves the split and clears the binding, so the second
            // lookup against `group` would race with state cleanup.
            let panes = [group.primaryTabId, group.secondaryTabId]
                .compactMap { id in tabs.first(where: { $0.guid == id }) }
            panes.forEach { $0.close() }
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
        guard !isIncognito else { return }
        let allBookmarks = bookmarkManager.getAllBookmarks()
        let focusingTabGuid = focusingTab?.guid

        for bookmark in allBookmarks {
            guard !bookmark.isFolder else { continue }

            // Split-view bookmarks bind to a live split via
            // `splitBookmarkBindings` rather than `guidInLocalDB`; route
            // them through the split-aware sync so isOpened/isActive
            // reflect the bound split.
            if splitBookmarkBindings[bookmark.guid] != nil {
                syncSplitBookmarkOpenedState(bookmarkGuid: bookmark.guid)
                continue
            }

            if let matchedTab = tabs.first(where: { $0.guidInLocalDB == bookmark.guid }) {
                syncBookmarkBinding(bookmark, with: matchedTab, focusingTabGuid: focusingTabGuid)
            } else {
                syncBookmarkBinding(bookmark, with: nil, focusingTabGuid: focusingTabGuid)
            }
        }

        updateNormalTabs()
    }
}
